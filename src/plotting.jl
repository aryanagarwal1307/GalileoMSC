################################################################################
# Runtime benchmarking
################################################################################

"""
Create a generic timing spec for a sequential particle filter.

Required keyword arguments:
- label: name shown in the plot legend
- pf_model: the Gen model used by the particle filter
- gm_args_builder: builds the full model args from (T, sim, template)
- online_args: converts full model args into the per-step args function get_args(t)
- argdiffs: the argdiff tuple for particle_filter_step!
- rejuvenate!: function(state, t, particles, rejuv_moves)
"""
function make_pf_timing_spec(; label,
                                pf_model,
                                gm_args_builder,
                                online_args,
                                argdiffs,
                                rejuvenate!)
    return (
        label = label,
        pf_model = pf_model,
        gm_args_builder = gm_args_builder,
        online_args = online_args,
        argdiffs = argdiffs,
        rejuvenate! = rejuvenate!
    )
end

function _model_config(model_key::Symbol; drift_std::Float64=0.25, msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    if model_key in (:particle_filter, :particlefilter, :pf, :static)
        return (
            key = :particle_filter,
            label = "particle filter",
            pf_model = particle_filter_model,
            gm_args_builder = (T, sim, template) -> (T, sim, template),
            history_runner = inference_with_history,
            timing_spec = particle_filter_timing_spec(label="particle filter")
        )
    elseif model_key in (:drift, :drift_model)
        return (
            key = :drift,
            label = "drift model",
            pf_model = drift_model,
            gm_args_builder = (T, sim, template) -> (T, sim, template, drift_std),
            history_runner = drift_inference_with_history,
            timing_spec = drift_timing_spec(label="drift model", drift_std=drift_std)
        )
    elseif model_key in (:msc, :msc_model, :collision_msc)
        return (
            key = :msc,
            label = "MSC v0",
            pf_model = msc_model,
            gm_args_builder = (T, sim, template) -> (T, sim, template, msc_params),
            history_runner = msc_inference_with_history,
            timing_spec = msc_timing_spec(label="MSC v0", params=msc_params)
        )
    else
        error("Unknown model key: $model_key. Use :particle_filter, :drift, or :msc.")
    end
end

_model_config(model_key::AbstractString; drift_std::Float64=0.25, msc_params::MSCParams=DEFAULT_MSC_PARAMS) =
    _model_config(Symbol(model_key); drift_std=drift_std, msc_params=msc_params)

function _model_config(config::NamedTuple; drift_std::Float64=0.25, msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    required = (:key, :label, :pf_model, :gm_args_builder, :history_runner, :timing_spec)
    all(key -> haskey(config, key), required) ||
        error("Custom model configs must include: $(join(string.(required), ", ")).")
    return config
end

function _resolve_model_configs(models; drift_std::Float64=0.25, msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    items = models isa AbstractVector ? models : [models]
    return [_model_config(item; drift_std=drift_std, msc_params=msc_params) for item in items]
end

function timing_spec(model_key; drift_std::Float64=0.25, msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    if model_key isa NamedTuple && haskey(model_key, :pf_model)
        return model_key
    end
    return _model_config(model_key; drift_std=drift_std, msc_params=msc_params).timing_spec
end

function _resolve_timing_specs(model_specs; drift_std::Float64=0.25, msc_params::MSCParams=DEFAULT_MSC_PARAMS)
    items = model_specs isa AbstractVector ? model_specs : [model_specs]
    return [timing_spec(item; drift_std=drift_std, msc_params=msc_params) for item in items]
end

function _scene_source_from_arg(scene_model, scene_args_builder, specs, drift_std::Float64, msc_params::MSCParams)
    if scene_model === nothing
        return (specs[1].pf_model, specs[1].gm_args_builder)
    elseif scene_model isa Symbol || scene_model isa AbstractString
        spec = timing_spec(scene_model; drift_std=drift_std, msc_params=msc_params)
        return (spec.pf_model, spec.gm_args_builder)
    else
        isnothing(scene_args_builder) &&
            error("scene_args_builder is required when scene_model is a Gen function.")
        return (scene_model, scene_args_builder)
    end
end

"""
Sample one shared bank of observation sequences.

The RNG is seeded inside this function so repeated calls with the same inputs
produce the same scenes. That gives a fair runtime comparison across models.
"""
function sample_shared_scene_bank(T::Int, sim, template;
                                  n_scenes::Int=10,
                                  scene_model=particle_filter_model,
                                  scene_args_builder=(T, sim, template) -> (T, sim, template),
                                  seed::Int=1)
    Random.seed!(seed)
    scenes = Vector{NamedTuple}(undef, n_scenes)
    scene_args = scene_args_builder(T, sim, template)

    for scene_idx in 1:n_scenes
        true_trace, = Gen.generate(scene_model, scene_args)
        observed_positions = observations_from_trace(true_trace)
        obs = make_observations(observed_positions)

        scenes[scene_idx] = (
            scene_idx = scene_idx,
            true_trace = true_trace,
            observed_positions = observed_positions,
            obs = obs,
            collision_time = detect_collision_time(observed_positions)
        )
    end

    return scenes
end

function _run_timed_filter_pass(spec,
                                gm_args,
                                obs::Vector{Gen.ChoiceMap};
                                particles::Int=20,
                                rejuv_moves::Int=1,
                                measure::Bool=true)
    get_args = spec.online_args(gm_args)
    state = Gen.initialize_particle_filter(spec.pf_model, get_args(0), EmptyChoiceMap(), particles)
    step_times_s = zeros(length(obs))

    for (t, obs_t) in enumerate(obs)
        elapsed = @elapsed begin
            Gen.particle_filter_step!(state, get_args(t), spec.argdiffs, obs_t)
            Gen.maybe_resample!(state, ess_threshold=particles / 2)
            spec.rejuvenate!(state, t, particles, rejuv_moves)
        end

        if measure
            step_times_s[t] = elapsed
        end
    end

    return step_times_s
end

"""
Benchmark per-step runtime for a single timing spec on a fixed scene bank.
"""
function benchmark_step_runtime(spec,
                                scenes,
                                T::Int,
                                sim,
                                template;
                                particles::Int=30,
                                rejuv_moves::Int=2,
                                warmup::Bool=true)
    gm_args = spec.gm_args_builder(T, sim, template)

    if warmup && !isempty(scenes)
        _run_timed_filter_pass(spec, gm_args, scenes[1].obs;
                               particles=particles,
                               rejuv_moves=rejuv_moves,
                               measure=false)
    end

    step_times_s = Matrix{Float64}(undef, length(scenes), T)
    collision_times = Vector{Union{Nothing,Int}}(undef, length(scenes))

    for (scene_idx, scene) in enumerate(scenes)
        println("Benchmarking $(spec.label), scene $scene_idx / $(length(scenes))", ", collision_time = $(scene.collision_time)")

        step_times_s[scene_idx, :] = _run_timed_filter_pass(spec, gm_args, scene.obs;
                                                           particles=particles,
                                                           rejuv_moves=rejuv_moves,
                                                           measure=true)
        collision_times[scene_idx] = scene.collision_time
    end

    mean_ms = 1000.0 .* vec(mean(step_times_s; dims=1))
    std_ms = 1000.0 .* vec(std(step_times_s; dims=1))
    median_ms = 1000.0 .* [median(view(step_times_s, :, t)) for t in 1:T]
    q25_ms = 1000.0 .* [quantile(view(step_times_s, :, t), 0.25) for t in 1:T]
    q75_ms = 1000.0 .* [quantile(view(step_times_s, :, t), 0.75) for t in 1:T]

    return (
        label = spec.label,
        step_times_s = step_times_s,
        mean_ms = mean_ms,
        std_ms = std_ms,
        median_ms = median_ms,
        q25_ms = q25_ms,
        q75_ms = q75_ms,
        collision_times = collision_times
    )
end

"""
Plot per-step inference time for one or more particle-filter models.

By default the line is the mean over scenes and the ribbon is +/- one std.
If summary=:median, the line is the median and the ribbon is the interquartile range.
"""
function plot_step_runtime_comparison(model_specs;
                                      T::Int,
                                      sim,
                                      template,
                                      scenes=nothing,
                                      n_scenes::Int=10,
                                      scene_model=nothing,
                                      scene_args_builder=nothing,
                                      particles::Int=30,
                                      rejuv_moves::Int=2,
                                      drift_std::Float64=0.25,
                                      msc_params::MSCParams=DEFAULT_MSC_PARAMS,
                                      seed::Int=1,
                                      warmup::Bool=true,
                                      summary::Symbol=:mean)
    specs = _resolve_timing_specs(model_specs; drift_std=drift_std, msc_params=msc_params)
    source_model, source_args_builder = _scene_source_from_arg(scene_model, scene_args_builder, specs, drift_std, msc_params)

    scene_bank = isnothing(scenes) ? sample_shared_scene_bank(T, sim, template;
                                                              n_scenes=n_scenes,
                                                              scene_model=source_model,
                                                              scene_args_builder=source_args_builder,
                                                              seed=seed) : scenes

    results = [benchmark_step_runtime(spec, scene_bank, T, sim, template;
                                      particles=particles,
                                      rejuv_moves=rejuv_moves,
                                      warmup=warmup) for spec in specs]

    ts = 1:T
    p = Plots.plot(xlabel="filter step t",
                   ylabel="runtime per step (ms)",
                   title="Per-step particle-filter runtime",
                   legend=:topleft)

    for result in results
        if summary == :mean
            center = result.mean_ms
            ribbon = result.std_ms
        elseif summary == :median
            center = result.median_ms
            ribbon = (result.median_ms .- result.q25_ms, result.q75_ms .- result.median_ms)
        else
            error("summary must be :mean or :median")
        end

        Plots.plot!(p, ts, center;
                    ribbon=ribbon,
                    label=result.label,
                    lw=3,
                    marker=:circle,
                    ms=3)
    end

    return (
        plot = p,
        scenes = scene_bank,
        results = results
    )
end

################################################################################
# Mass-ratio history comparison
################################################################################

function run_mass_ratio_history_comparison(models;
                                           T::Int,
                                           sim,
                                           template,
                                           obs=nothing,
                                           observed_positions=nothing,
                                           scene_model=nothing,
                                           scene_args_builder=nothing,
                                           particles::Int=30,
                                           rejuv_moves::Int=2,
                                           drift_std::Float64=0.25,
                                           msc_params::MSCParams=DEFAULT_MSC_PARAMS,
                                           seed::Int=1)
    configs = _resolve_model_configs(models; drift_std=drift_std, msc_params=msc_params)

    true_trace = nothing
    if obs === nothing
        if observed_positions === nothing
            Random.seed!(seed)
            source_model, source_builder = _scene_source_from_arg(scene_model, scene_args_builder, [configs[1].timing_spec], drift_std, msc_params)
            true_trace, = Gen.generate(source_model, source_builder(T, sim, template))
            observed_positions = observations_from_trace(true_trace)
        end
        obs = make_observations(observed_positions)
    end

    collision_time = observed_positions === nothing ? nothing : detect_collision_time(observed_positions)
    results = Vector{NamedTuple}(undef, length(configs))

    for (idx, config) in enumerate(configs)
        gm_args = config.gm_args_builder(T, sim, template)
        history = config.history_runner(gm_args, obs, particles, rejuv_moves)
        results[idx] = (
            key = config.key,
            label = config.label,
            history = history,
            collision_time = collision_time
        )
    end

    return (
        results = results,
        true_trace = true_trace,
        observed_positions = observed_positions,
        obs = obs,
        collision_time = collision_time
    )
end

function _history_label(item, idx)
    if item isa Pair
        return string(item.first)
    elseif hasproperty(item, :label)
        return string(getproperty(item, :label))
    else
        return "model $idx"
    end
end

function _history_value(item)
    if item isa Pair
        return item.second
    elseif hasproperty(item, :history)
        return getproperty(item, :history)
    else
        return item
    end
end

function _history_collision_time(item)
    hasproperty(item, :collision_time) ? getproperty(item, :collision_time) : nothing
end

function _is_history_vector(x)
    return x isa AbstractVector && !isempty(x) && hasproperty(x[1], :t)
end

function plot_mass_ratio_history(history; collision_time=nothing, use_quantiles=true, label="posterior mean")
    ts = [h.t for h in history]
    means = [h.mean for h in history]

    if use_quantiles
        lower = [h.q05 for h in history]
        upper = [h.q95 for h in history]
        yerr = (means .- lower, upper .- means)
    else
        stds = [h.std for h in history]
        yerr = stds
    end

    p = Plots.plot(
        ts, means;
        yerror=yerr,
        xlabel="time",
        ylabel="mass ratio",
        label=label,
        lw=2,
        marker=:circle
    )

    if collision_time !== nothing
        Plots.vline!(p, [collision_time], label="collision time", lw=2, ls=:dash)
    end

    return p
end

function plot_mass_ratio_history_comparison(history_results;
                                            collision_time=nothing,
                                            use_quantiles::Bool=true,
                                            title::AbstractString="Posterior mass ratio over time")
    items = hasproperty(history_results, :results) ? history_results.results : history_results
    items = items isa AbstractVector ? items : [items]

    p = Plots.plot(xlabel="time",
                   ylabel="mass ratio",
                   title=title,
                   legend=:topright)

    for (idx, item) in enumerate(items)
        history = _history_value(item)
        label = _history_label(item, idx)
        ts = [h.t for h in history]
        means = [h.mean for h in history]

        if use_quantiles
            lower = [h.q05 for h in history]
            upper = [h.q95 for h in history]
            ribbon = (means .- lower, upper .- means)
        else
            ribbon = [h.std for h in history]
        end

        Plots.plot!(p, ts, means;
                    ribbon=ribbon,
                    label=label,
                    lw=3,
                    marker=:circle,
                    ms=3)
    end

    collision_times = if collision_time !== nothing
        [collision_time]
    else
        unique([_history_collision_time(item) for item in items if _history_collision_time(item) !== nothing])
    end

    for (idx, ct) in enumerate(collision_times)
        Plots.vline!(p, [ct], label=idx == 1 ? "collision time" : "", lw=2, ls=:dash)
    end

    return p
end

function plot_capsule_activation_history(history_results;
                                         collision_time=nothing,
                                         show_switch::Bool=true,
                                         title::AbstractString="MSC capsule activation over time")
    items = if hasproperty(history_results, :results)
        history_results.results
    elseif _is_history_vector(history_results)
        [(label = "MSC v0", history = history_results, collision_time = collision_time)]
    else
        history_results
    end
    items = items isa AbstractVector ? items : [items]

    p = Plots.plot(xlabel="time",
                   ylabel="probability",
                   title=title,
                   legend=:topright,
                   ylims=(0, 1))

    plotted_any = false

    for (idx, item) in enumerate(items)
        history = _history_value(item)
        isempty(history) && continue
        hasproperty(history[1], :capsule_active_prob) || continue

        label = _history_label(item, idx)
        ts = [h.t for h in history]
        active_probs = [h.capsule_active_prob for h in history]
        Plots.plot!(p, ts, active_probs;
                    label="$(label) active",
                    lw=3,
                    marker=:circle,
                    ms=3)
        plotted_any = true

        if show_switch && hasproperty(history[1], :capsule_switch_prob)
            switch_probs = [h.capsule_switch_prob for h in history]
            Plots.plot!(p, ts, switch_probs;
                        label="$(label) switch",
                        lw=2,
                        ls=:dash)
        end
    end

    plotted_any || error("No history entries with capsule_active_prob were found.")

    collision_times = if collision_time !== nothing
        [collision_time]
    else
        unique([_history_collision_time(item) for item in items if _history_collision_time(item) !== nothing])
    end

    for (idx, ct) in enumerate(collision_times)
        Plots.vline!(p, [ct], label=idx == 1 ? "collision time" : "", lw=2, ls=:dot)
    end

    return p
end
