### A Pluto.jl notebook ###
# v0.20.24

using Markdown
using InteractiveUtils

# ╔═╡ 4f4e615e-2ce9-4e20-a278-0ba7aa963ba7
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    using GalileoMSC
    using Plots
end

# ╔═╡ e96c5f3c-cd11-49b2-b6f4-fc8949af468c
begin
    default_results_root = joinpath(@__DIR__, "..", "results")

    function latest_result_dir(root::AbstractString)
        isdir(root) || return root
        dirs = [joinpath(root, name) for name in readdir(root) if isdir(joinpath(root, name))]
        isempty(dirs) && return root
        return dirs[argmax(mtime.(dirs))]
    end

    results_dir = get(
        ENV,
        "GALILEO_MSC_RESULTS_DIR",
        latest_result_dir(default_results_root)
    )
end

# ╔═╡ 0a3797e6-bf68-4f7e-a992-c4e2aee4780b
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

# ╔═╡ 6a3dbeee-4725-483a-b8d8-db80f56ca2f1
begin
    summary_rows = read_csv_rows(joinpath(results_dir, "summary.csv"))
    replicate_rows = read_csv_rows(joinpath(results_dir, "replicates.csv"))
    metadata_rows = read_csv_rows(joinpath(results_dir, "metadata.csv"))
    metadata = Dict(Symbol(row.key) => row.value for row in metadata_rows)

    (
        results_dir = results_dir,
        models = get(metadata, :models, missing),
        runs_per_model = get(metadata, :runs_per_model, missing),
        ground_truth_mass = get(metadata, :ground_truth_mass, get(metadata, :mass_ratio, missing)),
        particles = get(metadata, :particles, missing),
        rejuv_moves = get(metadata, :rejuv_moves, missing),
        time_bin_size = get(metadata, :time_bin_size, 10)
    )
end

# ╔═╡ a8f57c15-aa9b-4c91-9162-8c032b463e16
begin
    function unique_in_order(values)
        out = eltype(values)[]
        for value in values
            value in out || push!(out, value)
        end
        return out
    end

    function metadata_number(metadata, key::Symbol)
        value = get(metadata, key, missing)
        value === missing && return nothing
        value isa Number && return Float64(value)
        parsed = tryparse(Float64, string(value))
        return parsed
    end

    function metadata_int(metadata, key::Symbol)
        value = get(metadata, key, missing)
        value === missing && return nothing
        value isa Integer && return Int(value)
        parsed = tryparse(Int, string(value))
        return parsed
    end

    function ground_truth_mass(metadata)
        value = metadata_number(metadata, :ground_truth_mass)
        value === nothing ? metadata_number(metadata, :mass_ratio) : value
    end

    function plot_time_bin_size(metadata)
        value = metadata_int(metadata, :time_bin_size)
        value === nothing ? 10 : value
    end

    function binned_mean_rows(rows, time_bin_size::Int)
        sorted_rows = sort(rows; by=row -> row.t)
        time_bin_size <= 1 && return [(t = row.t, mean = row.mean) for row in sorted_rows]
        isempty(sorted_rows) && return NamedTuple[]

        first_t = minimum([Int(row.t) for row in sorted_rows])
        last_t = maximum([Int(row.t) for row in sorted_rows])
        binned = NamedTuple[]

        for bin_start in first_t:time_bin_size:last_t
            bin_stop = bin_start + time_bin_size - 1
            bin_rows = [row for row in sorted_rows if bin_start <= row.t <= bin_stop]
            isempty(bin_rows) && continue

            ts = Float64[row.t for row in bin_rows]
            means = Float64[row.mean for row in bin_rows]
            push!(binned, (
                t = sum(ts) / length(ts),
                mean = sum(means) / length(means)
            ))
        end

        return binned
    end

    function history_items_from_summary(summary_rows, metadata)
        models = unique_in_order([row.model for row in summary_rows])
        collision_time = metadata_int(metadata, :collision_time)
        items = NamedTuple[]

        for model in models
            rows = sort(filter(row -> row.model == model, summary_rows); by=row -> row.t)
            history = [
                (
                    t = row.t,
                    mean = row.posterior_mean,
                    std = row.between_run_std,
                    q05 = row.q05_mean,
                    q25 = row.q25_mean,
                    q75 = row.q75_mean,
                    q95 = row.q95_mean
                )
                for row in rows
            ]
            push!(items, (
                label = rows[1].label,
                history = history,
                collision_time = collision_time
            ))
        end

        return items
    end
end

# ╔═╡ 16f0d1a0-6772-4d33-8e89-81563e1f7ad3
begin
    average_plot = plot_mass_ratio_history_comparison(
        history_items_from_summary(summary_rows, metadata);
        time_bin_size = plot_time_bin_size(metadata),
        title = "Average posterior mass ratio"
    )

    true_mass_ratio = ground_truth_mass(metadata)
    if true_mass_ratio !== nothing
        hline!(average_plot, [true_mass_ratio]; label="true mass ratio", lw=2, ls=:dot, color=:black)
    end

    average_plot
end

# ╔═╡ 92ffdf98-43dc-401f-838f-fd85ae780d58
begin
    function plot_replicate_means(replicate_rows, metadata)
        time_bin_size = plot_time_bin_size(metadata)
        p = plot(
            xlabel = "time",
            ylabel = "mass ratio",
            title = "Posterior mean by inference repeat",
            legend = :topright
        )

        models = unique_in_order([row.model for row in replicate_rows])
        colors = [:steelblue4, :darkorange3, :seagreen4, :purple3, :firebrick3, :gray30]

        for (model_idx, model) in enumerate(models)
            model_rows = filter(row -> row.model == model, replicate_rows)
            runs = unique_in_order([row.run for row in model_rows])

            for (run_idx, run) in enumerate(runs)
                raw_rows = filter(row -> row.run == run, model_rows)
                rows = binned_mean_rows(raw_rows, time_bin_size)
                label = run_idx == 1 ? string(raw_rows[1].label) : ""
                plot!(p, [row.t for row in rows], [row.mean for row in rows];
                      label = label,
                      color = colors[mod1(model_idx, length(colors))],
                      alpha = 0.22,
                      lw = 1.5)
            end
        end

        true_mass_ratio = ground_truth_mass(metadata)
        if true_mass_ratio !== nothing
            hline!(p, [true_mass_ratio]; label="true mass ratio", lw=2, ls=:dot, color=:black)
        end

        collision_time = metadata_int(metadata, :collision_time)
        if collision_time !== nothing
            vline!(p, [collision_time]; label="collision time", lw=2, ls=:dash, color=:gray30)
        end

        return p
    end

    replicate_plot = plot_replicate_means(replicate_rows, metadata)
end

# ╔═╡ 4a1bc21d-cd9b-4898-b2a9-34875ba8f648
replicate_plot

# ╔═╡ Cell order:
# ╠═4f4e615e-2ce9-4e20-a278-0ba7aa963ba7
# ╠═e96c5f3c-cd11-49b2-b6f4-fc8949af468c
# ╠═0a3797e6-bf68-4f7e-a992-c4e2aee4780b
# ╠═6a3dbeee-4725-483a-b8d8-db80f56ca2f1
# ╠═a8f57c15-aa9b-4c91-9162-8c032b463e16
# ╠═16f0d1a0-6772-4d33-8e89-81563e1f7ad3
# ╠═92ffdf98-43dc-401f-838f-fd85ae780d58
# ╠═4a1bc21d-cd9b-4898-b2a9-34875ba8f648
