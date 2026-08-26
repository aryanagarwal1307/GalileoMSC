# Parameters for the MSC model
Base.@kwdef struct MSCParams
    # Epsilon for numerical stability
    eps::Float64 = 1e-9

    # Collision Birth Features: 
    birth_gap_max::Float64 = 0.15               # Maximum gap for which objects are 'close'
    birth_gap_scale::Float64 = 0.015            # Gap gate parameter 
    birth_v_min::Float64 = 0.10                 # Minimum closing speed for which objects are 'approaching'
    birth_v_scale::Float64 = 0.015              # Closing speed gate parameter 
    birth_T_contact::Float64 = 0.16             # Contact prediction horizon
    birth_tau_scale::Float64 = 0.03             # Time to contact gate parameter
    birth_base::Float64 = 0.99                  # Base probability of collision when all predicates are satisfied
    birth_aabb_window::Float64 = 1.0            # AABB distance window for full birth predicate evaluation
    birth_background_weight::Float64 = 1e-8     # Uniform candidate weight outside the AABB window

    # Collision Death Features 
    min_active_steps::Int = 5                   # minimum steps for capsule to be active
    min_age_survival::Float64 = 1.0             # min survival prob early on
    age_decay_steps::Float64 = 25.0             # gradual decay of survival

    no_birth_weight::Float64 = 0.3              # weight of having no capsule births
    collision_mass_drift_std::Float64 = 1.0     # std for collision birth-time mass sampling
    tracked_mass_object::Int = 1                # object to summarize in mass history
end

const MSC_EVENT_TYPE_CODES = Dict(:collision => 1, :sliding => 2)
const MSC_EVENT_TYPES_BY_CODE = Dict(1 => :collision, 2 => :sliding)
const DEFAULT_MSC_PARAMS = MSCParams()
const MSC_CLAUSE_BRANCHES = Dict(:collision => 1)

# This is the abstract type for a capsule.
abstract type MSC end

# This struct is some diagnostic / functional stats for the entire state
struct MSCEventStats
    n_active::Int
    n_persisted::Int
    n_died::Int
    birth_prob::Float64           # Birth prob of the new capsule; in case of no birth – total prob of any birth
    born::Bool
end

# This is a capsule kind - collision of two objects (by ID)
struct CollisionMSC <: MSC
    id::Int
    a::Int
    b::Int
    birth_t::Int
    age::Int
end

# This is a capsule kind - sliding of one object (by ID) (just an example for now)
struct SlidingMSC <: MSC
    id::Int
    a::Int
    surface::Int
    birth_t::Int
    age::Int
end

# Here we track the state of the entire scene
struct MSCState
    # Vector of all (interacting) objects in the scene as a Bullet State
    objects::BulletState
    # Vector of all active capsules in the scene
    capsules::Vector{MSC}
    # Statistics for diagnostics and plotting
    event_stats::MSCEventStats
    # Most recent time/capsule clause that sampled an MSC latent.
    last_clause_checkpoint_t::Int
    last_clause_checkpoint_msc_id::Int
end

# A single additive latent update emitted by one capsule.
struct LatentDelta
    object_id::Int
    latent::Symbol
    delta::Float64
end

# A diff structure for all objects in a capsule, all latents to be updated
struct CapsuleDiff
    capsule_id::Int
    deltas::Vector{LatentDelta}
end
