### A Pluto.jl notebook ###
# v0.20.24

using Markdown
using InteractiveUtils

# ╔═╡ 19259a98-926f-4e15-9a78-145b7146334f
begin
    import Pkg
    Pkg.activate(joinpath(@__DIR__, ".."))

    include(joinpath(@__DIR__, "..", "src", "GalileoMSC.jl"))
    using .GalileoMSC
    using Random
    using Plots
end

# ╔═╡ b7becc6b-e2a4-4510-8abe-d63bcd4bc05f
rng = MersenneTwister(7);

# ╔═╡ d5831040-dabb-437e-bd04-0603df3f990c
scene = sample_random_scene(rng = rng);

# ╔═╡ 84ed514a-f6ea-4c2c-8c75-a54443d05b58
visualize_scene(scene)

# ╔═╡ 588fd62d-b6f5-4b17-b94a-6422a2341f46
positions = simulate_scene_positions(scene, 80);

# ╔═╡ 2a643d7b-9a7c-44c3-8736-71ab731317c9
visualize_scene(scene; positions = positions, frame = 40)

# ╔═╡ 8b6e2e80-3488-4c9b-8515-f2f52ce29904
plot_scene_trajectory(scene, positions)

# ╔═╡ Cell order:
# ╠═19259a98-926f-4e15-9a78-145b7146334f
# ╠═b7becc6b-e2a4-4510-8abe-d63bcd4bc05f
# ╠═d5831040-dabb-437e-bd04-0603df3f990c
# ╠═84ed514a-f6ea-4c2c-8c75-a54443d05b58
# ╠═588fd62d-b6f5-4b17-b94a-6422a2341f46
# ╠═2a643d7b-9a7c-44c3-8736-71ab731317c9
# ╠═8b6e2e80-3488-4c9b-8515-f2f52ce29904
