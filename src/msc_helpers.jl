# Calculate a cantor pair from 2 ints
@inline function cantor_pair(a::Int, b::Int)
    x = a - 1
    y = b - 1
    s = x + y
    return div(s * (s + 1), 2) + y + 1
end

# Reverse the cantor pair
@inline function cantor_unpair(z::Int)
    n = z - 1
    w = div(isqrt(8 * n + 1) - 1, 2)
    base = div(w * (w + 1), 2)
    y = n - base
    x = w - y
    return (x + 1, y + 1)
end

# Ensure that a capsule between (1, 2) and (2, 1) is the same
@inline function canonical_msc_pair(event_type::Symbol, a::Int, b::Int)
    event_type == :collision && return (min(a, b), max(a, b))
    return (a, b)
end

# Calculate the ID of a capsule given type and 2 object ints
function msc_capsule_id(event_type::Symbol, a::Int, b::Int)
    event_code = MSC_EVENT_TYPE_CODES[event_type]
    a, b = canonical_msc_pair(event_type, a, b)
    return cantor_pair(event_code, cantor_pair(a, b))
end

# Calculate the type and object ints from the capsule ID
function msc_capsule_key(id::Int)
    event_code, pair_code = cantor_unpair(id)
    a, b = cantor_unpair(pair_code)
    return (event_type = MSC_EVENT_TYPES_BY_CODE[event_code], a = a, b = b)
end

#### Helpers to manage capsules ####

# Initializer
function default_msc_event_stats()
    return MSCEventStats(0, 0, 0, 0.0, false)
end

# Initializer
function initial_msc_state(objects::BulletState, params::MSCParams=MSCParams())
    tracked_mass_object(objects, params.tracked_mass_object)
    return MSCState(objects, MSC[], default_msc_event_stats(), 0, 0)
end

function aggregate_capsule_diffs(capsule_diffs::Vector{CapsuleDiff})
    n_deltas = 0
    for capsule_diff in capsule_diffs
        n_deltas += length(capsule_diff.deltas)
    end

    totals = Dict{Tuple{Int,Symbol},Float64}()
    sizehint!(totals, n_deltas)

    for capsule_diff in capsule_diffs
        for delta in capsule_diff.deltas
            key = (delta.object_id, delta.latent)
            totals[key] = get(totals, key, 0.0) + delta.delta
        end
    end

    return totals
end

function apply_capsule_diffs(objects::BulletState, capsule_diffs::Vector{CapsuleDiff})
    totals = aggregate_capsule_diffs(capsule_diffs)
    isempty(totals) && return objects

    new_latents = copy(objects.latents)
    for ((object_id, latent), delta) in totals
        if latent == :log_mass
            current = new_latents[object_id]
            new_latents[object_id] = update_latents(current, object_mass(current) * exp(delta))
        elseif latent == :log_lateralFriction
            current = new_latents[object_id]
            new_latents[object_id] = update_latents(
                current;
                lateralFriction=object_lateral_friction(current) * exp(delta)
            )
        else
            error("Unsupported MSC diff latent: $latent")
        end
    end

    return Accessors.setproperties(objects; latents=new_latents)
end

# Helper to get all the active capsule IDs #TODO: Not sure if this is memory efficient
function active_capsule_ids(capsules::Vector{MSC})
    ids = Set{Int}()
    sizehint!(ids, length(capsules))
    @inbounds for cap in capsules
        push!(ids, cap.id)
    end
    return ids
end

function extract_msc_capsules(tr::Gen.Trace, t::Int)
    return get_retval(tr)[t].capsules
end

function extract_msc_event_stats(tr::Gen.Trace, t::Int)
    return get_retval(tr)[t].event_stats
end

function extract_current_msc_mass(tr::Gen.Trace, t::Int, params::MSCParams=DEFAULT_MSC_PARAMS)
    state = get_retval(tr)[t]
    object_id = tracked_mass_object(state.objects, params.tracked_mass_object)
    return object_mass(state.objects.latents[object_id])
end

function summarize_msc_masses(traces, t::Int, params::MSCParams=DEFAULT_MSC_PARAMS)
    ms = Float64[extract_current_msc_mass(tr, t, params) for tr in traces]
    return (
        mean = mean(ms),
        std = std(ms),
        q25 = quantile(ms, 0.25),
        q75 = quantile(ms, 0.75),
        q05 = quantile(ms, 0.05),
        q95 = quantile(ms, 0.95),
        masses = ms
    )
end

function extract_current_msc_friction(tr::Gen.Trace, t::Int, object_id::Int)
    state = get_retval(tr)[t]
    return object_lateral_friction(state.objects.latents[object_id])
end

function summarize_msc_frictions(traces, t::Int; object_indices=nothing)
    isempty(traces) && return Dict{Int,NamedTuple}()
    state = get_retval(traces[1])[t]
    indices = object_indices === nothing ? dynamic_object_indices(state.objects) : object_indices

    return Dict(
        object_id => begin
            values = Float64[extract_current_msc_friction(tr, t, object_id) for tr in traces]
            (
                mean = mean(values),
                std = std(values),
                q05 = quantile(values, 0.05),
                q25 = quantile(values, 0.25),
                q75 = quantile(values, 0.75),
                q95 = quantile(values, 0.95),
                frictions = values
            )
        end
        for object_id in indices
    )
end

function _mean_active_capsule_age(capsules::Vector{MSC})
    isempty(capsules) && return 0.0
    return mean(Float64[cap.age for cap in capsules])
end

function summarize_msc_capsules(traces, t::Int)
    capsules_by_trace = [extract_msc_capsules(tr, t) for tr in traces]
    event_stats = [extract_msc_event_stats(tr, t) for tr in traces]
    active_counts = [length(capsules) for capsules in capsules_by_trace]
    active = active_counts .> 0

    birth_events = [stats.born for stats in event_stats]
    death_counts = [stats.n_died for stats in event_stats]
    death_events = death_counts .> 0
    switch_events = birth_events .| death_events

    return (
        capsule_active_prob = mean(Float64.(active)),
        capsule_switch_prob = mean(Float64.(switch_events)),
        capsule_birth_prob = mean(Float64.(birth_events)),
        capsule_death_prob = mean(Float64.(death_events)),
        capsule_mean_active_count = mean(Float64.(active_counts)),
        capsule_mean_death_count = mean(Float64.(death_counts)),
        capsule_mean_age = mean(Float64[_mean_active_capsule_age(capsules) for capsules in capsules_by_trace]),
        capsule_mean_birth_probability = mean(Float64[stats.birth_prob for stats in event_stats])
    )
end

function msc_timing_spec(; label="MSC v0", params::MSCParams=DEFAULT_MSC_PARAMS)
    return make_pf_timing_spec(
        label = label,
        pf_model = msc_model,
        gm_args_builder = (T, sim, template) -> (T, sim, template, params),
        online_args = gm_args -> (t -> (t, gm_args[2:4]...)),
        argdiffs = (UnknownChange(), NoChange(), NoChange(), NoChange()),
        rejuvenate! = function (state, t, particles, rejuv_moves)
            for i in 1:particles, s in 1:rejuv_moves
                state.traces[i], _ = msc_initial_latents_move(state.traces[i])
                checkpoint = msc_last_clause_checkpoint(state.traces[i], t)
                if checkpoint[1] != 0
                    state.traces[i], _ = msc_proposal(state.traces[i], checkpoint...)
                end
            end
            return nothing
        end
    )
end
