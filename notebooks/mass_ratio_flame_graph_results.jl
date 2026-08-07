### A Pluto.jl notebook ###
# v0.20.24

using Markdown
using InteractiveUtils

# ╔═╡ 8f470a9b-1a33-4936-8fae-c5f213b74f11
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using Plots
end

# ╔═╡ 25ee1280-01c3-4a19-9f9a-96afaa3afeed
begin
    default_results_root = joinpath(@__DIR__, "..", "results")

    job_number = get(ENV, "GALILEO_MSC_JOB_NUMBER", "")
    selected_model = get(ENV, "GALILEO_MSC_FLAME_MODEL", "msc")
    selected_run_override = get(ENV, "GALILEO_MSC_FLAME_RUN", nothing)
end

# ╔═╡ 107e4893-09c5-466a-91a0-3f59126f7ea2
begin
    function latest_result_dir(root::AbstractString)
        isdir(root) || return root
        dirs = [
            joinpath(root, name)
            for name in readdir(root)
            if isdir(joinpath(root, name)) && isfile(joinpath(root, name, "flame_graph.csv"))
        ]
        isempty(dirs) && return root
        return dirs[argmax(mtime.(dirs))]
    end

    function result_dir_for_job(root::AbstractString, job::AbstractString)
        isempty(strip(job)) && return latest_result_dir(root)

        dir = joinpath(root, "mass_ratio_replicates_$(strip(job))")
        isdir(dir) || error("No result directory found for job $(strip(job)): $dir")
        return dir
    end

    results_dir = get(
        ENV,
        "GALILEO_MSC_RESULTS_DIR",
        result_dir_for_job(default_results_root, job_number)
    )

    flame_graph_path = get(
        ENV,
        "GALILEO_MSC_FLAME_GRAPH_FILE",
        joinpath(results_dir, "flame_graph.csv")
    )
end

# ╔═╡ a8d8d5d2-f1e9-4dd6-8d5a-4b9c23588886
begin
    function split_csv_line(line::AbstractString)
        fields = String[]
        field = IOBuffer()
        in_quotes = false
        i = firstindex(line)

        while i <= lastindex(line)
            c = line[i]
            if c == '"'
                next_i = nextind(line, i)
                if in_quotes && next_i <= lastindex(line) && line[next_i] == '"'
                    print(field, '"')
                    i = next_i
                else
                    in_quotes = !in_quotes
                end
            elseif c == ',' && !in_quotes
                push!(fields, String(take!(field)))
            else
                print(field, c)
            end
            i = nextind(line, i)
        end

        push!(fields, String(take!(field)))
        return fields
    end

    function parse_csv_value(raw::AbstractString)
        isempty(raw) && return missing

        int_value = tryparse(Int, raw)
        int_value === nothing || return int_value

        float_value = tryparse(Float64, raw)
        float_value === nothing || return float_value

        return raw
    end

    function read_csv_rows(path::AbstractString)
        lines = readlines(path)
        isempty(lines) && return NamedTuple[]

        header = Symbol.(split_csv_line(lines[1]))
        rows = NamedTuple[]
        for line in lines[2:end]
            isempty(strip(line)) && continue
            values = parse_csv_value.(split_csv_line(line))
            push!(rows, NamedTuple{Tuple(header)}(Tuple(values)))
        end
        return rows
    end
end

# ╔═╡ c0c8c215-92aa-41d4-8c77-9c0866c0e709
begin
    flame_rows = read_csv_rows(flame_graph_path)
    available_runs = sort(unique([
        (model = string(row.model), run = Int(row.run))
        for row in flame_rows
        if row.run !== missing
    ]); by = item -> (item.model, item.run))
    model_runs = filter(item -> item.model == selected_model, available_runs)
    selected_run = if selected_run_override === nothing
        isempty(model_runs) && error("No saved flame-graph runs found for model=$selected_model.")
        first(model_runs).run
    else
        parse(Int, selected_run_override)
    end

    (
        flame_graph_path = flame_graph_path,
        selected_model = selected_model,
        selected_run = selected_run,
        available_runs = available_runs
    )
end

# ╔═╡ be54423d-8152-409b-9422-d071717ad61c
begin
    function first_nonmissing(values)
        for value in values
            value === missing && continue
            return value
        end
        return nothing
    end

    function saved_flame_graph_plot(rows; model::AbstractString, run::Int)
        selected = filter(row -> string(row.model) == model && Int(row.run) == run, rows)
        isempty(selected) && error("No flame graph rows found for model=$model, run=$run.")

        ts = sort(unique([Int(row.t) for row in selected if row.t !== missing]))
        label = first_nonmissing([row.label for row in selected])
        title = "MSC capsule flame graph: $(label === nothing ? model : label) run $run"

        capsule_rows = filter(
            row -> row.capsule_index !== missing && row.active_probability !== missing,
            selected
        )

        if isempty(capsule_rows)
            p = plot(
                ts,
                zeros(length(ts));
                xlabel = "time",
                ylabel = "capsule",
                title = title,
                legend = false,
                ylims = (0, 1),
                color = :white
            )
            if !isempty(ts)
                annotate!(p, sum(ts) / length(ts), 0.5, "no sampled active capsules")
            end
        else
            capsule_indices = sort(unique([Int(row.capsule_index) for row in capsule_rows]))
            labels = String[]

            for idx in capsule_indices
                label_value = first_nonmissing([
                    row.capsule_label
                    for row in capsule_rows
                    if Int(row.capsule_index) == idx
                ])
                push!(labels, string(label_value))
            end

            t_index = Dict(t => idx for (idx, t) in enumerate(ts))
            capsule_index = Dict(idx => row for (row, idx) in enumerate(capsule_indices))
            activity = zeros(length(capsule_indices), length(ts))

            for row in capsule_rows
                t = Int(row.t)
                cap = Int(row.capsule_index)
                if haskey(t_index, t) && haskey(capsule_index, cap)
                    activity[capsule_index[cap], t_index[t]] = Float64(row.active_probability)
                end
            end

            ys = collect(1:length(labels))
            p = heatmap(
                ts,
                ys,
                activity;
                xlabel = "time",
                ylabel = "capsule",
                yticks = (ys, labels),
                title = title,
                color = :viridis,
                clims = (0, 1),
                colorbar_title = "active probability",
                legend = false
            )
        end

        collision_time = first_nonmissing([row.collision_time for row in selected])
        if collision_time !== nothing
            vline!(p, [Float64(collision_time)]; label = "", lw = 2, ls = :dot, color = :white)
        end

        return p
    end
end

# ╔═╡ 364b62f7-1419-497d-b0f4-44f490892e77
saved_flame_plot = saved_flame_graph_plot(
    flame_rows;
    model = selected_model,
    run = selected_run
)

# ╔═╡ 277047e8-b8ce-4963-83d1-8407adea2155
saved_flame_plot

# ╔═╡ Cell order:
# ╠═8f470a9b-1a33-4936-8fae-c5f213b74f11
# ╠═25ee1280-01c3-4a19-9f9a-96afaa3afeed
# ╠═107e4893-09c5-466a-91a0-3f59126f7ea2
# ╠═a8d8d5d2-f1e9-4dd6-8d5a-4b9c23588886
# ╠═c0c8c215-92aa-41d4-8c77-9c0866c0e709
# ╠═be54423d-8152-409b-9422-d071717ad61c
# ╠═364b62f7-1419-497d-b0f4-44f490892e77
# ╠═277047e8-b8ce-4963-83d1-8407adea2155
