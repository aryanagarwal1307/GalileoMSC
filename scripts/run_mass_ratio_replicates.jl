#!/usr/bin/env julia

const PROJECT_ROOT = "/gpfs/radev/project/yildirim/aa2842/GalileoMSC/"

using Dates
using Distributed
using Gen
using GalileoMSC
using Plots
using Printf
using Random
using Statistics

const DEFAULT_OUT_DIR = joinpath(
    PROJECT_ROOT,
    "results",
    "mass_ratio_replicates_" * Dates.format(now(), "yyyymmdd_HHMMSS")
)

function usage()
    return """
    Run repeated posterior mass-ratio inference on one shared ramp scene.

    Defaults match notebooks/model_plots.jl:
      models: particle_filter,drift
      runs per model: 20
      scene: mass_ratio=2.0, frictions=(0.3,0.3), positions=(0.5,1.5)

    Usage:
      julia --project=. scripts/run_mass_ratio_replicates.jl [options]

    Options:
      --out-dir PATH             Directory for CSVs and plots
      --runs N                   Independent inference repeats per model [20]
      --workers N                Worker processes to add for pmap [min(4, CPU_THREADS - 1)]
      --models a,b               Models to run [particle_filter,drift]
      --T N                      Number of time steps [120]
      --particles N              Particle count [20]
      --rejuv-moves N            Rejuvenation moves per step [1]
      --drift-std X              Drift model mass transition std [1.5]
      --proposal-drift-std X     Drift model mass MH proposal std [0.25]
      --time-bin-size N          Plot bin width in time steps [10]
      --seed N                   Base inference seed [11]
      --scene-seed N             Seed for the shared observed scene [11]
      --scene-model NAME         Model used to sample observations [particle_filter]
      --mass-ratio X             Ground-truth ramp-object mass ratio for generated observations [2.0]
      --obj-frictions X,Y        Object frictions [0.3,0.3]
      --obj-positions X,Y        Initial object positions [0.5,1.5]
      --slope X                  Ramp slope [0.6666666666666666]
      --table-ramp-intersection X [0.0]
      --help                     Show this message
    """
end

function parse_cli(args)
    opts = Dict{String,String}(
        "out_dir" => DEFAULT_OUT_DIR,
        "runs" => "20",
        "workers" => string(min(4, max(Sys.CPU_THREADS - 1, 1))),
        "models" => "particle_filter,drift",
        "T" => "120",
        "particles" => "20",
        "rejuv_moves" => "1",
        "drift_std" => "1.5",
        "proposal_drift_std" => "0.25",
        "time_bin_size" => "10",
        "seed" => "11",
        "scene_seed" => "11",
        "scene_model" => "particle_filter",
        "mass_ratio" => "2.0",
        "obj_frictions" => "0.3,0.3",
        "obj_positions" => "0.5,1.5",
        "slope" => string(2 / 3),
        "table_ramp_intersection" => "0.0"
    )

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--help" || arg == "-h"
            println(usage())
            exit(0)
        elseif startswith(arg, "--")
            raw = arg[3:end]
            if occursin("=", raw)
                key, value = split(raw, "="; limit=2)
            else
                i == length(args) && error("Missing value for $arg")
                key = raw
                i += 1
                value = args[i]
            end
            opts[replace(key, "-" => "_")] = value
        else
            error("Unexpected positional argument: $arg")
        end
        i += 1
    end

    return opts
end

function parse_pair(raw::AbstractString, name::AbstractString)
    pieces = split(raw, ",")
    length(pieces) == 2 || error("$name must be two comma-separated numbers.")
    return (parse(Float64, strip(pieces[1])), parse(Float64, strip(pieces[2])))
end

function parse_models(raw::AbstractString)
    models = Symbol[]
    for piece in split(raw, ",")
        stripped = strip(piece)
        isempty(stripped) || push!(models, Symbol(stripped))
    end
    isempty(models) && error("--models must include at least one model.")
    return models
end

function build_config(opts)
    return (
        out_dir = abspath(opts["out_dir"]),
        runs = parse(Int, opts["runs"]),
        workers = parse(Int, opts["workers"]),
        models = parse_models(opts["models"]),
        T = parse(Int, opts["T"]),
        particles = parse(Int, opts["particles"]),
        rejuv_moves = parse(Int, opts["rejuv_moves"]),
        drift_std = parse(Float64, opts["drift_std"]),
        proposal_drift_std = parse(Float64, opts["proposal_drift_std"]),
        time_bin_size = parse(Int, opts["time_bin_size"]),
        seed = parse(Int, opts["seed"]),
        scene_seed = parse(Int, opts["scene_seed"]),
        scene_model = Symbol(opts["scene_model"]),
        mass_ratio = parse(Float64, opts["mass_ratio"]),
        obj_frictions = parse_pair(opts["obj_frictions"], "obj_frictions"),
        obj_positions = parse_pair(opts["obj_positions"], "obj_positions"),
        slope = parse(Float64, opts["slope"]),
        table_ramp_intersection = parse(Float64, opts["table_ramp_intersection"])
    )
end

function ensure_workers(n_requested::Int)
    n_requested >= 0 || error("--workers must be nonnegative.")
    existing_extra_workers = nprocs() - 1
    missing = n_requested - existing_extra_workers
    if missing > 0
        addprocs(missing; exeflags="--project=$(PROJECT_ROOT)")
    end
    return nprocs() - 1
end

function disconnect_scene(scene)
    try
        if isdefined(GalileoMSC, :pb)
            getfield(GalileoMSC, :pb).disconnect(scene.client)
        end
    catch err
        @warn "Could not disconnect PyBullet client" exception=(err, catch_backtrace())
    end
    return nothing
end

function make_scene(config)
    return create_ramp_simulation(;
        mass_ratio = config.mass_ratio,
        obj_frictions = config.obj_frictions,
        obj_positions = config.obj_positions,
        slope = config.slope,
        tableRampIntersection = config.table_ramp_intersection
    )
end

function generate_observed_positions(config)
    Random.seed!(config.scene_seed)
    scene = make_scene(config)
    constraints = mass_constraint(config.mass_ratio)

    trace = if config.scene_model in (:particle_filter, :particlefilter, :pf, :static)
        first(Gen.generate(particle_filter_model, (config.T, scene.sim, scene.init_state), constraints))
    elseif config.scene_model in (:drift, :drift_model)
        first(Gen.generate(drift_model, (config.T, scene.sim, scene.init_state, config.drift_std), constraints))
    else
        disconnect_scene(scene)
        error("Unsupported --scene-model $(config.scene_model). Use particle_filter or drift.")
    end

    ground_truth_mass = get_choices(trace)[:latents => :obj1 => :mass]
    observed_positions = observations_from_trace(trace)
    collision_time = detect_collision_time(observed_positions)
    disconnect_scene(scene)
    return observed_positions, collision_time, ground_truth_mass
end

function _galileo_disconnect_scene(scene)
    try
        if isdefined(GalileoMSC, :pb)
            getfield(GalileoMSC, :pb).disconnect(scene.client)
        end
    catch
    end
    return nothing
end

function _galileo_make_scene(task)
    return GalileoMSC.create_ramp_simulation(;
        mass_ratio = task.mass_ratio,
        obj_frictions = task.obj_frictions,
        obj_positions = task.obj_positions,
        slope = task.slope,
        tableRampIntersection = task.table_ramp_intersection
    )
end

function _galileo_run_mass_task(task)
    Random.seed!(task.seed)
    scene = _galileo_make_scene(task)
    obs = GalileoMSC.make_observations(task.observed_positions)
    started = time()

    result = GalileoMSC.run_mass_ratio_history_comparison(
        [task.model];
        T = task.T,
        sim = scene.sim,
        template = scene.init_state,
        obs = obs,
        observed_positions = task.observed_positions,
        ground_truth_mass = task.mass_ratio,
        particles = task.particles,
        rejuv_moves = task.rejuv_moves,
        drift_std = task.drift_std,
        proposal_drift_std = task.proposal_drift_std,
        seed = task.seed
    )

    model_result = result.results[1]
    history = [
        (
            t = Int(h.t),
            mean = Float64(h.mean),
            std = Float64(h.std),
            q05 = Float64(h.q05),
            q25 = Float64(h.q25),
            q75 = Float64(h.q75),
            q95 = Float64(h.q95)
        )
        for h in model_result.history
    ]

    elapsed_s = time() - started
    _galileo_disconnect_scene(scene)

    return (
        model = task.model,
        label = String(model_result.label),
        run = task.run,
        seed = task.seed,
        elapsed_s = elapsed_s,
        history = history
    )
end

function setup_workers()
    for pid in workers()
        remotecall_wait(Core.eval, pid, Main, quote
            using GalileoMSC
            using Random

            function _galileo_disconnect_scene(scene)
                try
                    if isdefined(GalileoMSC, :pb)
                        getfield(GalileoMSC, :pb).disconnect(scene.client)
                    end
                catch
                end
                return nothing
            end

            function _galileo_make_scene(task)
                return GalileoMSC.create_ramp_simulation(;
                    mass_ratio = task.mass_ratio,
                    obj_frictions = task.obj_frictions,
                    obj_positions = task.obj_positions,
                    slope = task.slope,
                    tableRampIntersection = task.table_ramp_intersection
                )
            end

            function _galileo_run_mass_task(task)
                Random.seed!(task.seed)
                scene = _galileo_make_scene(task)
                obs = GalileoMSC.make_observations(task.observed_positions)
                started = time()

                result = GalileoMSC.run_mass_ratio_history_comparison(
                    [task.model];
                    T = task.T,
                    sim = scene.sim,
                    template = scene.init_state,
                    obs = obs,
                    observed_positions = task.observed_positions,
                    ground_truth_mass = task.mass_ratio,
                    particles = task.particles,
                    rejuv_moves = task.rejuv_moves,
                    drift_std = task.drift_std,
                    proposal_drift_std = task.proposal_drift_std,
                    seed = task.seed
                )

                model_result = result.results[1]
                history = [
                    (
                        t = Int(h.t),
                        mean = Float64(h.mean),
                        std = Float64(h.std),
                        q05 = Float64(h.q05),
                        q25 = Float64(h.q25),
                        q75 = Float64(h.q75),
                        q95 = Float64(h.q95)
                    )
                    for h in model_result.history
                ]

                elapsed_s = time() - started
                _galileo_disconnect_scene(scene)

                return (
                    model = task.model,
                    label = String(model_result.label),
                    run = task.run,
                    seed = task.seed,
                    elapsed_s = elapsed_s,
                    history = history
                )
            end
        end)
    end

    return nothing
end

function task_seed(base_seed::Int, run::Int, model_idx::Int)
    return base_seed + 10_000 * model_idx + run
end

function build_tasks(config, observed_positions)
    tasks = NamedTuple[]
    for (model_idx, model) in enumerate(config.models), run in 1:config.runs
        push!(tasks, (
            model = model,
            run = run,
            seed = task_seed(config.seed, run, model_idx),
            observed_positions = observed_positions,
            T = config.T,
            particles = config.particles,
            rejuv_moves = config.rejuv_moves,
            drift_std = config.drift_std,
            proposal_drift_std = config.proposal_drift_std,
            mass_ratio = config.mass_ratio,
            obj_frictions = config.obj_frictions,
            obj_positions = config.obj_positions,
            slope = config.slope,
            table_ramp_intersection = config.table_ramp_intersection
        ))
    end
    return tasks
end

function summarize_results(task_results)
    by_model = Dict{Symbol,Vector{NamedTuple}}()
    for result in task_results
        push!(get!(by_model, result.model, NamedTuple[]), result)
    end

    rows = NamedTuple[]
    for model in sort(collect(keys(by_model)); by=string)
        results = sort(by_model[model]; by=r -> r.run)
        label = results[1].label
        T = length(results[1].history)

        for t in 1:T
            means = [r.history[t].mean for r in results]
            stds = [r.history[t].std for r in results]
            q05s = [r.history[t].q05 for r in results]
            q25s = [r.history[t].q25 for r in results]
            q75s = [r.history[t].q75 for r in results]
            q95s = [r.history[t].q95 for r in results]
            between_run_std = length(means) > 1 ? std(means) : 0.0

            push!(rows, (
                model = model,
                label = label,
                t = t,
                n_runs = length(results),
                posterior_mean = mean(means),
                between_run_std = between_run_std,
                between_run_se = between_run_std / sqrt(length(means)),
                posterior_std_mean = mean(stds),
                q05_mean = mean(q05s),
                q25_mean = mean(q25s),
                q75_mean = mean(q75s),
                q95_mean = mean(q95s)
            ))
        end
    end

    return rows
end

function csv_escape(x)
    if x === nothing || x === missing
        return ""
    end

    s = string(x)
    if occursin('"', s) || occursin(',', s) || occursin('\n', s)
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    end
    return s
end

function write_csv(path, header, rows)
    open(path, "w") do io
        println(io, join(header, ","))
        for row in rows
            println(io, join(csv_escape.(row), ","))
        end
    end
    return path
end

function write_replicates_csv(path, task_results)
    header = [
        "model", "label", "run", "t", "mean", "std",
        "q05", "q25", "q75", "q95", "seed", "elapsed_s"
    ]
    rows = Vector{Vector{Any}}()
    for result in sort(task_results; by=r -> (string(r.model), r.run))
        for h in result.history
            push!(rows, [
                result.model, result.label, result.run, h.t, h.mean, h.std,
                h.q05, h.q25, h.q75, h.q95, result.seed, result.elapsed_s
            ])
        end
    end
    return write_csv(path, header, rows)
end

function write_summary_csv(path, summary_rows)
    header = [
        "model", "label", "t", "n_runs", "posterior_mean",
        "between_run_std", "between_run_se", "posterior_std_mean",
        "q05_mean", "q25_mean", "q75_mean", "q95_mean"
    ]
    rows = [
        [
            row.model, row.label, row.t, row.n_runs, row.posterior_mean,
            row.between_run_std, row.between_run_se, row.posterior_std_mean,
            row.q05_mean, row.q25_mean, row.q75_mean, row.q95_mean
        ]
        for row in summary_rows
    ]
    return write_csv(path, header, rows)
end

function write_metadata_csv(path, config, collision_time, ground_truth_mass, elapsed_s, n_workers)
    rows = [
        ["created_at", string(now())],
        ["project_root", PROJECT_ROOT],
        ["julia_version", string(VERSION)],
        ["models", join(string.(config.models), ",")],
        ["runs_per_model", config.runs],
        ["workers", n_workers],
        ["T", config.T],
        ["particles", config.particles],
        ["rejuv_moves", config.rejuv_moves],
        ["drift_std", config.drift_std],
        ["proposal_drift_std", config.proposal_drift_std],
        ["time_bin_size", config.time_bin_size],
        ["seed", config.seed],
        ["scene_seed", config.scene_seed],
        ["scene_model", config.scene_model],
        ["mass_ratio", config.mass_ratio],
        ["ground_truth_mass", ground_truth_mass],
        ["ground_truth_mass_address", ":latents => :obj1 => :mass"],
        ["ground_truth_mass_note", "Synthetic scene generation constrains the initial mass ratio. For drift scene generation this is the constrained initial mass."],
        ["obj_frictions", join(config.obj_frictions, ",")],
        ["obj_positions", join(config.obj_positions, ",")],
        ["slope", config.slope],
        ["table_ramp_intersection", config.table_ramp_intersection],
        ["collision_time", collision_time],
        ["elapsed_s", elapsed_s],
        ["summary", "posterior_mean is the mean of per-run posterior means; batch plot ribbon is +/- between_run_std by default; q*_mean columns are retained for optional quantile plots"]
    ]
    return write_csv(path, ["key", "value"], rows)
end

function write_observed_positions_csv(path, observed_positions)
    rows = Vector{Vector{Any}}()
    for (t, step_positions) in enumerate(observed_positions)
        for obj_idx in 1:length(step_positions)
            position = step_positions[obj_idx]
            push!(rows, [t, obj_idx, position[1], position[2], position[3]])
        end
    end
    return write_csv(path, ["t", "object", "x", "y", "z"], rows)
end

function plot_summary(summary_rows, config, collision_time, ground_truth_mass, path_prefix)
    items = NamedTuple[]
    for model in unique([row.model for row in summary_rows])
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

    p = plot_mass_ratio_history_comparison(
        items;
        time_bin_size = config.time_bin_size,
        title = "Average posterior mass ratio over $(config.runs) inference repeats"
    )
    Plots.hline!(p, [ground_truth_mass]; label="true mass ratio", lw=2, ls=:dot, color=:black)

    png_path = path_prefix * ".png"
    pdf_path = path_prefix * ".pdf"
    Plots.savefig(p, png_path)
    Plots.savefig(p, pdf_path)
    return p, png_path, pdf_path
end

function main(args)
    config = build_config(parse_cli(args))
    config.runs >= 1 || error("--runs must be at least 1.")
    config.T >= 1 || error("--T must be at least 1.")
    config.particles >= 1 || error("--particles must be at least 1.")
    config.time_bin_size >= 1 || error("--time-bin-size must be at least 1.")

    mkpath(config.out_dir)
    n_workers = ensure_workers(config.workers)
    setup_workers()
    println("Output directory: $(config.out_dir)")
    println("Worker processes: $n_workers")
    println("Runs per model: $(config.runs)")
    println("Models: $(join(string.(config.models), ", "))")
    println("Plot time bin size: $(config.time_bin_size)")

    started = time()
    observed_positions, collision_time, ground_truth_mass = generate_observed_positions(config)
    println("Shared scene collision_time = $(collision_time)")
    println("Ground-truth mass ratio = $(ground_truth_mass)")

    tasks = build_tasks(config, observed_positions)
    task_results = pmap(_galileo_run_mass_task, tasks)
    summary_rows = summarize_results(task_results)

    replicates_path = write_replicates_csv(joinpath(config.out_dir, "replicates.csv"), task_results)
    summary_path = write_summary_csv(joinpath(config.out_dir, "summary.csv"), summary_rows)
    positions_path = write_observed_positions_csv(joinpath(config.out_dir, "observed_positions.csv"), observed_positions)
    _, png_path, pdf_path = plot_summary(summary_rows, config, collision_time, ground_truth_mass, joinpath(config.out_dir, "average_mass_ratio_history"))

    elapsed_s = time() - started
    metadata_path = write_metadata_csv(joinpath(config.out_dir, "metadata.csv"), config, collision_time, ground_truth_mass, elapsed_s, n_workers)

    @printf("Finished in %.2f seconds.\n", elapsed_s)
    println("Wrote:")
    println("  $summary_path")
    println("  $replicates_path")
    println("  $metadata_path")
    println("  $positions_path")
    println("  $png_path")
    println("  $pdf_path")
end

main(ARGS)
