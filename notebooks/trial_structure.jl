### A Pluto.jl notebook ###
# v0.20.28

# ╔═╡ 71a053c0-1fc0-4b62-b224-f97e7f9383c4
begin
    using CairoMakie
    using JSON
    using SHA
    using LinearAlgebra: norm
    using Printf
    fmt(pattern, values...) = Printf.format(Printf.Format(pattern), values...)

    # ── EDIT FIGURE TEXT HERE ────────────────────────────────────────────────
    # Change these strings, then rerun this cell. Numerical positions still come
    # from the audited timing data below. Formats control generated number labels.
    figure_text = (
        title = "Trial Timings",
        panel_a = "A   Stimulus timeline by mass ratio (ramp : table)",
        panel_b = "B   Trial duration by condition",
        conditions = ["Baseline", "Pre", "During", "Post"],
        ratios = ["1 : 8", "1 : 4", "1 : 2"],
        empty = "Empty scene",
        stationary = "Objects stationary",
        motion_onset = "Ramp motion starts",
        collision = "Collision",
        clip_end = "Nominal clip end",
        motion_end = "Motion ends",
        moving = "Moving",
        probe_key = "Probe:",
        fixation = "Fixation",
        video = "Video playback",
        frozen = "Frozen frame",
        freeze_onset = "Probe / Freeze onset",
        total = "Total",
        time_axis = "Time relative to video onset (s)",
        condition_format = "%s  (%+d ms)",
        duration_format = "%.3f s",
        short_duration_format = "%.1f s",
        interval_format = "%.1f–%.1f s",
        footnote = "Panel A shows the three early-stopping ratios. Ratios 2:1, 4:1 and 8:1 remain moving at the last sample (5.483 s).",
    )
    # ── END EDITABLE TEXT ────────────────────────────────────────────────────

    # One executable cell; Pluto installs CairoMakie/JSON in its notebook environment.
    # Outside Pluto, use an environment containing CairoMakie 0.15 and JSON 0.21.
    # Nothing is exported unless this switch is enabled. PDF size is 13 × 6 inches.
    export_figure = false
    export_directory = @__DIR__  # Export beside the notebook; refreshes the repo PNG.
    trajectory_directory = joinpath(@__DIR__, "..", "stimuli", "generated", "trajectories")

    # Audited main: 9817eb31611a2e8be4763d87f70f95f178e275b0 (2026-11-05).
    # Timing snapshot: experiment/app/{experiment.config,main,validate,design}.ts,
    # stimuli/config/stimuli.toml, stimuli/video/encode_videos.py, and the local
    # video_manifest.json. FFprobe independently confirmed all 13 MP4s: 330 frames,
    # 60 Hz, 5.5 s. Generated assets are gitignored; the empirical summary below
    # keeps this notebook runnable on a fresh checkout without external files.
    # Collision is 786 physics ticks / 240 Hz AFTER the 60-frame intro.
    fps, physics_hz = 60, 240
    empty_frames, preview_frames, action_frames = 48, 12, 270
    intro_frames = empty_frames + preview_frames
    empty_end = empty_frames // fps
    motion_onset = intro_frames // fps
    collision_action = 786 // physics_hz
    collision_time = motion_onset + collision_action
    nominal_end = (intro_frames + action_frames) // fps
    last_sample = motion_onset + (action_frames - 1) // fps
    fixation, freeze = 2000 // 1000, 1500 // 1000
    names = figure_text.conditions
    offsets_ms = [-1000, -200, 200, 1000]
    probe_keys = ["baseline", "preCollision", "collision", "postCollision"]
    intended_probes = collision_time .+ offsets_ms .// 1000
    # Encoder/validate.ts use nearest-frame rounding, with ties to the later frame.
    probe_frames = [intro_frames + floor(Int, (collision_action + o // 1000) * fps + 1 // 2)
                    for o in offsets_ms]
    probes = probe_frames .// fps
    freeze_ends = probes .+ freeze
    totals = fixation .+ probes .+ freeze

    @assert (empty_end, motion_onset, collision_time, nominal_end) == (4//5, 1, 171//40, 11//2)
    @assert intended_probes == [131//40, 163//40, 179//40, 211//40]
    @assert probe_frames == [197, 245, 269, 317]  # Manifest agrees for every stimulus.
    @assert all(probes .- intended_probes .== 1//120)
    @assert all(probes .- collision_time .== offsets_ms .// 1000 .+ 1//120)
    @assert all(freeze_ends .- probes .== freeze)
    @assert all(totals .== [407//60, 91//12, 479//60, 527//60])
    @assert all(0 .< probes .< nominal_end)
    @assert probes[2] < collision_time < probes[3]

    # Operational stopping criterion, NOT exact zero velocity or a simulator sleep
    # flag: BOTH objects have ||v|| ≤ 1 mm/s AND ||ω|| ≤ 0.01 rad/s at every
    # subsequent recorded frame, with ≥0.25 s of confirmation. No extrapolation.
    # The interval (preceding sample, first qualifying sample] expresses 60 Hz
    # sampling uncertainty. A missing stop is right-censored at last_sample.
    linear_threshold, angular_threshold, minimum_dwell = 0.001, 0.01, 0.25
    function sustained_rest_frame(data; vlim=linear_threshold, wlim=angular_threshold,
                                  dwell=minimum_dwell)
        frames = data["frames"]
        quiet = [all(norm(o["linear_velocity"]) <= vlim &&
                     norm(o["angular_velocity"]) <= wlim
                     for o in values(f["objects"])) for f in frames]
        last_active = findlast(!, quiet)
        first_quiet = isnothing(last_active) ? 1 : last_active + 1
        first_quiet <= length(frames) || return nothing
        t = frames[first_quiet]["time_seconds"]
        t > data["collision"]["first_contact_time_seconds"] || return nothing
        frames[end]["time_seconds"] - t >= dwell || return nothing
        return Int(frames[first_quiet]["frame"])
    end

    # Empirical trajectory snapshot: ID, physical ramp/table mass ratio, zero-based
    # first sustained-rest frame (0 = not observed), SHA256 of original JSON bytes.
    # No practice stimulus is included in this 12-stimulus summary.
    motion_snapshot = [
        ("brick_to_metal_congruent", 0.25, 235, "84700c7ffcbafacc4939d1ec434b037ae84e9c47a2a9c39c0f8854192f190f97"),
        ("brick_to_metal_violation", 4.0, 0, "96dc77553211df9c546825b40e3961b5c03859385067a1b40170c2aa7ee3375a"),
        ("brick_to_wood_congruent", 2.0, 0, "1d467f07ea620f39b14ddf66192d55d5a6abd98e97775e7550196fedaed8f5b6"),
        ("brick_to_wood_violation", 0.5, 248, "e17b2d72e5beff70e5ee6f1ed3414a3eabbdffac6bc77d741f7e41203fc973e2"),
        ("metal_to_brick_congruent", 4.0, 0, "534951dff4044ec9d7525c28b3b7bd4036d558c52859d75aef2a66150e67e748"),
        ("metal_to_brick_violation", 0.25, 235, "64dcc5572431b2c23f7f0582c3ce1f6f6d19ce20de4b701d4cdf525f7bc65de5"),
        ("metal_to_wood_congruent", 8.0, 0, "5a64894eab032b333821630a57d82a4d79dac972d80794fb92b823ed424146f0"),
        ("metal_to_wood_violation", 0.125, 234, "05abe5a6107afbca048ffdc25b17b6ff6f13c990dcdecabd65fda87219763eb5"),
        ("wood_to_brick_congruent", 0.5, 248, "e346721f5f0057812265dfc3a9761c4023e5e971a9fd5082bf07d1221fb36000"),
        ("wood_to_brick_violation", 2.0, 0, "23ac981320b21f1a3943870d12c2f75022ed5d4a1ad034ea25643db6efb6a73d"),
        ("wood_to_metal_congruent", 0.125, 234, "ed4f1310e885435182c29b613d9dbd7589514e4ded648f48938648e5901ca001"),
        ("wood_to_metal_violation", 8.0, 0, "c6f259251735c35c9c7c86cee047e1494d09ba808fd22d961fc7441dd1cd9086"),
    ]
    # If original trajectories are present, verify hashes, timing, and the empirical
    # calculation rather than silently using stale data. A partial set is allowed;
    # absent files retain the explicitly versioned snapshot above.
    for (id, ratio, stored_frame, digest) in motion_snapshot
        path = joinpath(trajectory_directory, id * ".json")
        isfile(path) || continue
        bytes = read(path)
        @assert bytes2hex(sha256(bytes)) == digest "Trajectory changed: $id; re-audit the snapshot."
        data = JSON.parse(String(bytes))
        @assert data["condition_id"] == id && data["stimulus"]["mass_ratio"] == ratio
        @assert data["collision"]["first_contact_substep"] == 786
        @assert data["timing"]["video_fps"] == fps
        @assert length(data["frames"]) == action_frames
        @assert [f["frame"] for f in data["frames"]] == collect(0:action_frames-1)
        @assert all(isapprox(f["time_seconds"], f["frame"] / fps; atol=1e-12)
                    for f in data["frames"])
        calculated = sustained_rest_frame(data)
        @assert something(calculated, 0) == stored_frame "Rest estimate changed: $id."
    end
    # Paired appearances have identical recorded dynamics at each DIRECTED ratio.
    # Reciprocal ratios are distinct physical situations: 2, 4, 8 have no observed
    # stop in the clip. Panel A shows only the three early-stopping ratios below.
    rest_groups = [
        (ratio=0.125, frame=234),
        (ratio=0.25, frame=235),
        (ratio=0.5, frame=248),
    ]
    @assert count(x -> x[3] > 0, motion_snapshot) == 6
    for group in rest_groups
        matches = filter(x -> x[2] == group.ratio, motion_snapshot)
        @assert length(matches) == 2 && all(x -> x[3] == group.frame, matches)
        @assert motion_onset + group.frame // fps < intended_probes[4]
        @assert last_sample - (motion_onset + group.frame // fps) >= minimum_dwell
    end

    function trial_structure_figure()
        colors = ["#3976A8", "#268B86", "#8062A7", "#CB8234"]
        ink, muted, red = "#252A30", "#626970", "#BE3F48"
        motion_end_color = "#D88D94"
        fixation_color, freeze_color = "#CFD2D5", "#F0F1F2"
        fig = Figure(size=(936, 432), backgroundcolor=:white, fontsize=9.5,
                     fonts=(; regular="DejaVu Sans", bold="DejaVu Sans Bold"),
                     figure_padding=(20, 20, 12, 12))
        Label(fig[0, 1], figure_text.title, fontsize=18, font=:bold,
              halign=:left, tellwidth=false, color=ink)
        top = Axis(fig[1, 1], title=figure_text.panel_a, titlealign=:left,
                   titlefont=:bold, titlesize=10.5, xgridvisible=false,
                   ygridvisible=false, backgroundcolor=:white,
                   yticks=([3, 2, 1], figure_text.ratios),
                   yticklabelsize=9, yticklabelpad=10, yticksvisible=false)
        bottom = Axis(fig[2, 1], title=figure_text.panel_b, titlealign=:left,
                      titlefont=:bold, titlesize=10.5, xgridvisible=false,
                      ygridvisible=false, backgroundcolor=:white,
                      xlabel=figure_text.time_axis, xlabelsize=10,
                      xticks=([-2, 0, 1, 2, 3, 4, 5, 6], ["−2", "0", "1", "2", "3", "4", "5", "6"]),
                      yticks=([4, 3, 2, 1], [fmt(figure_text.condition_format, n, o)
                                             for (n, o) in zip(names, offsets_ms)]),
                      yticklabelsize=9, yticklabelpad=10, yticksvisible=false,
                      xtrimspine=true, spinewidth=0.6, xtickwidth=0.6, xticksize=3)
        linkxaxes!(top, bottom)
        xlims!(bottom, -2.05, 7.8)
        ylims!(top, -0.15, 4.25)
        ylims!(bottom, 0.40, 4.85)
        hidexdecorations!(top)
        hidespines!(top)
        hidespines!(bottom, :l, :r, :t)

        # Small primitives keep all horizontal positions in seconds.
        label(ax, x, y, s; kwargs...) = text!(ax, Float64(x), y; text=s,
            color=ink, align=(:center, :center), kwargs...)
        function segment(ax, start, stop, y, height, color)
            poly!(ax, Rect2f(Float64(start), y - height/2, Float64(stop-start), height);
                  color=color, strokewidth=0)
        end
        function guide(ax, x, low, high; color="#D9DDE0", style=:solid, width=0.65)
            lines!(ax, [Float64(x), Float64(x)], [low, high];
                   color=color, linewidth=width, linestyle=style)
        end
        # Bands are centered exactly on event time. Their small display width is
        # a visual treatment, not an estimate of duration or timing uncertainty.
        function event_band(ax, time, y, height, color)
            width = 0.06
            # Opaque colors keep collision identically dark red on every
            # condition background. Light red is reserved for motion end.
            segment(ax, time-width/2, time+width/2, y, height, color)
        end
        # Three full stimulus bars. Texture/congruence are collapsed ONLY within
        # the same directed physical ratio. Rest starts at the first confirmed
        # quiet sample; its preceding frame remains the lower uncertainty bound.
        stimulus_h = 0.54
        for t in (0, empty_end, motion_onset)
            guide(top, t, 0.70, 3.30)
        end
        guide(top, nominal_end, 0.70, 3.50; color="#AAB1B7")
        guide(top, collision_time, 0.70, 3.55; color=(red, 0.45), style=:dash)
        for (group, y) in zip(rest_groups, [3.0, 2.0, 1.0])
            stop = motion_onset + group.frame // fps
            segment(top, 0, empty_end, y, stimulus_h, "#ECEEF0")
            segment(top, empty_end, motion_onset, y, stimulus_h, "#BFC6CC")
            segment(top, motion_onset, stop, y, stimulus_h, "#A8BAC5")
            segment(top, stop, nominal_end, y, stimulus_h, "#F0F1F2")
            label(top, (motion_onset+collision_time)/2, y, figure_text.moving; fontsize=8.5)
            # Motion end uses a soft red band and centered circle; probe dots
            # remain at the top of each bar. Collision uses a darker red diamond.
            event_band(top, stop, y, stimulus_h, motion_end_color)
            scatter!(top, [Float64(stop)], [y]; color=motion_end_color,
                     marker=:circle, markersize=5.5, strokecolor=:white, strokewidth=0.4)
            text!(top, 6.75, y; text=fmt(figure_text.duration_format, stop),
                  color=motion_end_color, fontsize=9, align=(:center, :center))
            event_band(top, collision_time, y, stimulus_h, red)
            guide(top, collision_time, y-stimulus_h/2, y+stimulus_h/2;
                  color=red, width=1.6)
            scatter!(top, [Float64(collision_time)], [y]; color=red,
                     marker=:diamond, markersize=5.5, strokecolor=:white, strokewidth=0.4)
            for (p, color) in zip(probes, colors)
                guide(top, p, y-stimulus_h/2, y+stimulus_h/2; color=color, width=1.2)
                scatter!(top, [Float64(p)], [y+stimulus_h/2]; color=color,
                         markersize=5.5, strokecolor=:white, strokewidth=0.6)
            end
        end
        # Outside labels and leaders keep the very short stationary interval clear.
        lines!(top, [-0.45, 0.4], [3.72, 3.29]; color=muted, linewidth=0.65)
        label(top, -0.50, 3.97, figure_text.empty * "\n" *
              fmt(figure_text.interval_format, 0, empty_end); fontsize=8)
        guide(top, (empty_end+motion_onset)/2, 3.29, 3.72; color=muted)
        label(top, 0.9, 3.97, figure_text.stationary * "\n" *
              fmt(figure_text.interval_format, empty_end, motion_onset); fontsize=8)
        lines!(top, Float64[motion_onset, 2.0], [3.29, 3.72]; color=muted, linewidth=0.65)
        label(top, 2.35, 3.97, figure_text.motion_onset * "\n" *
              fmt(figure_text.short_duration_format, motion_onset); fontsize=8)
        text!(top, Float64(collision_time), 3.97; text=figure_text.collision * "\n" *
              fmt(figure_text.duration_format, collision_time), color=red,
              fontsize=8.5, font=:bold, align=(:center, :center))
        label(top, 5.55, 3.97, figure_text.clip_end * "\n" *
              fmt(figure_text.short_duration_format, nominal_end); fontsize=8)
        # A single inline key identifies the motion-end color and centered dot.
        event_band(top, 6.15, 3.97, 0.36, motion_end_color)
        scatter!(top, [6.15], [3.97]; color=motion_end_color, markersize=5.5,
                 strokecolor=:white, strokewidth=0.4)
        text!(top, 6.75, 3.97; text=figure_text.motion_end, color=motion_end_color,
              fontsize=8.5, font=:bold, align=(:center, :center))
        # Shared color key: these marks mean the same probe times in both panels.
        text!(top, 0.9, 0.12; text=figure_text.probe_key, fontsize=8,
              color=muted, align=(:right, :center))
        for (i, x) in enumerate([1.1, 2.45, 3.5, 4.7])
            scatter!(top, [x], [0.12]; color=colors[i], markersize=5)
            text!(top, x+0.12, 0.12; text=names[i], fontsize=8,
                  color=ink, align=(:left, :center))
        end

        # Collision is a common reference across all four rows. The band also
        # crosses Baseline/Pre frozen frames; actual-contact diamonds appear only
        # where video playback reaches collision.
        for (low, high) in ((0.45, 0.65), (1.35, 1.65), (2.35, 2.65),
                            (3.35, 3.65), (4.35, 4.53))
            guide(bottom, collision_time, low, high; color=(red, 0.5), style=:dash)
        end
        guide(bottom, 0, 0.5, 4.55; color="#BDC3C8")
        text!(bottom, 7.6, 4.68; text=figure_text.total, fontsize=8.5, color=muted,
              align=(:right, :center))
        bar_h = 0.54
        for (i, y) in enumerate([4.0, 3.0, 2.0, 1.0])
            p, endpoint = probes[i], freeze_ends[i]
            segment(bottom, -fixation, 0, y, bar_h, fixation_color)
            segment(bottom, 0, p, y, bar_h, colors[i])
            segment(bottom, p, endpoint, y, bar_h, freeze_color)
            event_band(bottom, collision_time, y, bar_h, red)
            label(bottom, -fixation/2, y, fmt(figure_text.short_duration_format, fixation); fontsize=8.5)
            text!(bottom, Float64(p/2), y; text=fmt(figure_text.duration_format, p), color=:white,
                  fontsize=9, font=:bold, align=(:center, :center))
            label(bottom, p+freeze/2, y, fmt(figure_text.short_duration_format, freeze); fontsize=8.5)
            guide(bottom, p, y-bar_h/2, y+bar_h/2; color=colors[i], width=1.1)
            scatter!(bottom, [Float64(p)], [y+bar_h/2]; color=colors[i],
                     markersize=5.5, strokecolor=:white, strokewidth=0.6)
            text!(bottom, 7.6, y; text=fmt(figure_text.duration_format, totals[i]), fontsize=9,
                  color=ink, align=(:right, :center))
            if p >= collision_time
                guide(bottom, collision_time, y-bar_h/2, y+bar_h/2; color=red, width=1.6)
                scatter!(bottom, [Float64(collision_time)], [y]; color=red,
                         marker=:diamond, markersize=5, strokecolor=:white, strokewidth=0.4)
            end
        end
        Legend(fig[3, 1],
               [PolyElement(color=fixation_color), PolyElement(color="#6E7E8C"),
                PolyElement(color=freeze_color, strokecolor="#CFD2D5", strokewidth=0.5),
                MarkerElement(color=ink, marker=:circle, markersize=5)],
               [figure_text.fixation, figure_text.video, figure_text.frozen,
                figure_text.freeze_onset];
               orientation=:horizontal, framevisible=false, labelsize=8.5,
               patchsize=(12, 7), colgap=18, padding=(0, 0, 0, 0), tellwidth=false)
        Label(fig[4, 1],
              figure_text.footnote,
              fontsize=7.5, color=muted, halign=:left, tellwidth=false,
              justification=:left)
        rowsize!(fig.layout, 1, Relative(0.44))
        rowgap!(fig.layout, 9)
        return fig
    end

    trial_figure = trial_structure_figure()
    if export_figure
        mkpath(export_directory)
        # Makie units are PDF points; 936/72 = 13 in and 432/72 = 6 in.
        save(joinpath(export_directory, "trial_structure.png"), trial_figure; px_per_unit=300/72)
        save(joinpath(export_directory, "trial_structure.pdf"), trial_figure; pt_per_unit=1)
    end
    # Audit tables remain accessible in Pluto's workspace without adding panels.
    timing_audit = [(; condition=names[i], offset_ms=offsets_ms[i],
                      intended_probe_s=Float64(intended_probes[i]), frame=probe_frames[i],
                      playback_s=Float64(probes[i]), freeze_end_s=Float64(freeze_ends[i]),
                      total_s=Float64(totals[i])) for i in eachindex(names)]
    trial_figure
end

# ╔═╡ Cell order:
# ╠═71a053c0-1fc0-4b62-b224-f97e7f9383c4
