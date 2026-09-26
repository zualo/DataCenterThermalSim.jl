using DataCenterThermalSim
using Plots

const DURATION_S = 900.0
const OUTPUT_DIR = joinpath(@__DIR__, "..", "output")
mkpath(OUTPUT_DIR)

params = SimulationParams()
profile = if length(ARGS) >= 1
    load_telemetry_csv(ARGS[1])
else
    generate_benchmark_profile(DURATION_S)
end
solution = run_simulation(params, profile)

time_h = solution.t ./ 3600
die_C, fluid_C, integral_error = solution[1, :], solution[2, :], solution[3, :]
flow = similar(die_C)
pump_W = similar(die_C)
for i in eachindex(solution.t)
    j = clamp(searchsortedlast(profile.time_s, solution.t[i]), 1, length(profile.time_s) - 1)
    α = (solution.t[i] - profile.time_s[j]) / (profile.time_s[j + 1] - profile.time_s[j])
    power = muladd(α, profile.power_W[j + 1] - profile.power_W[j], profile.power_W[j])
    dT_die = (power - (die_C[i] - fluid_C[i]) / params.R_th_K_W) / params.C_die_J_K
    flow[i] = controlled_mass_flow(params, die_C[i], dT_die, integral_error[i])
    pump_W[i] = pump_power(params, flow[i])
end

trapz(y, x) = sum(diff(x) .* ((y[1:end-1] .+ y[2:end]) ./ 2))
it_energy_kWh = trapz(profile.power_W, profile.time_s) / 3.6e6
pump_energy_kWh = trapz(pump_W, solution.t) / 3.6e6
full_speed_energy_kWh = params.pump_power_max_W * (solution.t[end] - solution.t[1]) / 3.6e6
max_die_C = maximum(die_C)
println("DataCenterThermalSim transient run")
println("Duration:               $(round(solution.t[end] - solution.t[1], digits=1)) s")
println("IT energy:              $(round(it_energy_kWh, digits=3)) kWh")
println("Pump energy:            $(round(pump_energy_kWh, digits=4)) kWh")
println("Full-speed pump energy: $(round(full_speed_energy_kWh, digits=4)) kWh")
println("Pump energy reduction:  $(round(100 * (1 - pump_energy_kWh / full_speed_energy_kWh), digits=1))% vs full speed")
println("Peak die temperature:   $(round(max_die_C, digits=2)) °C")
println("Peak coolant temp:      $(round(maximum(fluid_C), digits=2)) °C")
println("Flow range:             $(round(minimum(flow), digits=4))–$(round(maximum(flow), digits=4)) kg/s")
println("Time above setpoint:    $(round(sum(diff(solution.t) .* (die_C[1:end-1] .> params.T_setpoint_C)), digits=1)) s")

power_kW = profile.power_W ./ 1000
fig = plot(layout=(2, 1), size=(1100, 760), left_margin=8Plots.mm,
           right_margin=8Plots.mm, bottom_margin=5Plots.mm, legend=:topright,
           fontfamily="sans-serif", dpi=180)
plot!(fig[1], profile.time_s ./ 60, power_kW; color=:darkorange, lw=2.2,
      label="IT load", ylabel="IT load (kW)", xlabel="Time (min)",
      title="Rack thermal response and dynamic liquid cooling", grid=:on)
die_axis = twinx(fig[1])
plot!(die_axis, time_h .* 60, die_C; color=:firebrick, lw=2.4,
      label="Die temperature", ylabel="Temperature (°C)")
hline!(die_axis, [params.T_setpoint_C]; color=:firebrick, ls=:dash, lw=1.4,
       label="70 °C target")
plot!(fig[2], time_h .* 60, flow; color=:royalblue, lw=2.2,
      label="Coolant mass flow", ylabel="Mass flow (kg/s)", xlabel="Time (min)",
      grid=:on, legend=:topleft)
pump_axis = twinx(fig[2])
plot!(pump_axis, time_h .* 60, pump_W ./ 1000; color=:seagreen, lw=2.2,
      label="Pump power", ylabel="Pump power (kW)", legend=:topright)
savefig(fig, joinpath(OUTPUT_DIR, "thermal_transient.png"))
println("Plot saved to:          $(joinpath(OUTPUT_DIR, "thermal_transient.png"))")
