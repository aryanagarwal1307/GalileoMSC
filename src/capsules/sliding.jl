################################################################################
# Sliding capsule
################################################################################


# Helper to calculate collision birth and death probability
function calculate_sliding_birth_prob(objects::BulletState, a::Int, b::Int, params::MSCParams)

end

# Helper to check if a slidng capsule is already in the given vector
function has_active_collision(active_ids::Set{Int}, a::Int, b::Int)
    return msc_capsule_id(:sliding, a, b) in active_ids
end

# Helper to increase the age of a capsule
function increment_age(cap::SlidingMSC)
    return SlidingMSC(cap.id, cap.a, cap.surface, cap.birth_t, cap.age + 1)
end

# A function that checks if sliding is at all possible

