module DataCenterThermalSim

using CSV
using DataFrames
using DifferentialEquations

export SimulationParams, TelemetryProfile, generate_benchmark_profile,
       load_telemetry_csv, thermal_dynamics!, run_simulation,
       controlled_mass_flow, pump_power

"""Physical and controller parameters; all values use SI units (temperatures in °C)."""
Base.@kwdef struct SimulationParams
    C_die_J_K::Float64 = 2.0e4
    C_fluid_J_K::Float64 = 2.5e4
    R_th_K_W::Float64 = 1.0e-3
    cp_J_kgK::Float64 = 4180.0
    T_inlet_C::Float64 = 20.0
    T_setpoint_C::Float64 = 70.0
    m_dot_min_kg_s::Float64 = 0.02
    m_dot_max_kg_s::Float64 = 0.50
    m_dot_nominal_kg_s::Float64 = 0.08
    Kp_kg_s_K::Float64 = 0.04
    Ki_kg_s_K_s::Float64 = 2.5e-3
    Kd_kg_s_s_K::Float64 = 2.0e-3
    pump_power_max_W::Float64 = 1500.0
    T_die_initial_C::Float64 = 35.0
    T_fluid_initial_C::Float64 = 25.0
    reltol::Float64 = 1e-6
    abstol::Float64 = 1e-8
end

function validate_params(p::SimulationParams)
    values = (p.C_die_J_K, p.C_fluid_J_K, p.R_th_K_W, p.cp_J_kgK,
              p.T_inlet_C, p.T_setpoint_C, p.m_dot_min_kg_s, p.m_dot_max_kg_s,
              p.m_dot_nominal_kg_s, p.Kp_kg_s_K, p.Ki_kg_s_K_s, p.Kd_kg_s_s_K,
              p.pump_power_max_W, p.T_die_initial_C, p.T_fluid_initial_C,
              p.reltol, p.abstol)
    all(isfinite, values) || throw(ArgumentError("simulation parameters must be finite"))
    p.C_die_J_K > 0 || throw(ArgumentError("C_die_J_K must be positive"))
    p.C_fluid_J_K > 0 || throw(ArgumentError("C_fluid_J_K must be positive"))
    p.R_th_K_W > 0 || throw(ArgumentError("R_th_K_W must be positive"))
    p.cp_J_kgK > 0 || throw(ArgumentError("cp_J_kgK must be positive"))
    0 < p.m_dot_min_kg_s <= p.m_dot_nominal_kg_s <= p.m_dot_max_kg_s ||
        throw(ArgumentError("require 0 < m_dot_min <= m_dot_nominal <= m_dot_max"))
    p.Kp_kg_s_K >= 0 && p.Ki_kg_s_K_s >= 0 && p.Kd_kg_s_s_K >= 0 ||
        throw(ArgumentError("PID gains must be nonnegative"))
    p.pump_power_max_W > 0 || throw(ArgumentError("pump_power_max_W must be positive"))
    p.reltol > 0 && p.abstol > 0 || throw(ArgumentError("solver tolerances must be positive"))
    return nothing
end

"""Validated, linearly interpolated compute power telemetry in seconds and watts."""
struct TelemetryProfile
    time_s::Vector{Float64}
    power_W::Vector{Float64}
    function TelemetryProfile(time_s::AbstractVector, power_W::AbstractVector)
        length(time_s) == length(power_W) || throw(ArgumentError("time and power lengths differ"))
        length(time_s) >= 2 || throw(ArgumentError("profile needs at least two samples"))
        t, q = Float64.(time_s), Float64.(power_W)
        all(isfinite, t) && all(isfinite, q) || throw(ArgumentError("profile values must be finite"))
        all(diff(t) .> 0) || throw(ArgumentError("time_s must be strictly increasing"))
        all(q .>= 0) || throw(ArgumentError("power_W must be nonnegative"))
        new(t, q)
    end
end

@inline function power_at(profile::TelemetryProfile, t::Real)
    ts = profile.time_s
    t <= ts[1] && return profile.power_W[1]
    t >= ts[end] && return profile.power_W[end]
    i = searchsortedlast(ts, t)
    α = (t - ts[i]) / (ts[i + 1] - ts[i])
    return muladd(α, profile.power_W[i + 1] - profile.power_W[i], profile.power_W[i])
end

"""Create deterministic 5–30 kW workload telemetry with ramped server-load spikes."""
function generate_benchmark_profile(duration_seconds::Real)
    isfinite(duration_seconds) && duration_seconds > 0 ||
        throw(ArgumentError("duration_seconds must be finite and positive"))
    step_s = 5.0
    t = collect(0.0:step_s:Float64(duration_seconds))
    t[end] < duration_seconds && push!(t, Float64(duration_seconds))
    q = fill(5_000.0, length(t))
    spikes = ((0.12, 0.22, 30_000.0), (0.36, 0.48, 24_000.0),
              (0.63, 0.76, 30_000.0), (0.84, 0.93, 20_000.0))
    for (i, ti) in pairs(t), (a, b, peak) in spikes
        a * duration_seconds <= ti <= b * duration_seconds && (q[i] = peak)
    end
    return TelemetryProfile(t, q)
end

"""Load CSV telemetry with required `time_s` and `p_it_W` columns."""
function load_telemetry_csv(path::AbstractString)
    df = CSV.read(path, DataFrame)
    required = (:time_s, :p_it_W)
    all(in(propertynames(df)), required) ||
        throw(ArgumentError("CSV must contain columns time_s and p_it_W"))
    return TelemetryProfile(df.time_s, df.p_it_W)
end

@inline function controlled_mass_flow(p::SimulationParams, T_die_C::Real,
                                      dT_die_dt_K_s::Real, integral_error_K_s::Real)
    error = T_die_C - p.T_setpoint_C
    raw = p.m_dot_nominal_kg_s + p.Kp_kg_s_K * error +
          p.Ki_kg_s_K_s * integral_error_K_s + p.Kd_kg_s_s_K * dT_die_dt_K_s
    return clamp(raw, p.m_dot_min_kg_s, p.m_dot_max_kg_s)
end

@inline pump_power(p::SimulationParams, m_dot_kg_s::Real) =
    p.pump_power_max_W * (m_dot_kg_s / p.m_dot_max_kg_s)^3

"""In-place ODE RHS. State is `[T_die, T_fluid, integral_error]`."""
function thermal_dynamics!(du, u, context, t)
    p, profile = context.params, context.profile
    T_die, T_fluid, integral_error = u
    q_it = power_at(profile, t)
    q_die_fluid = (T_die - T_fluid) / p.R_th_K_W
    dT_die = (q_it - q_die_fluid) / p.C_die_J_K
    m_dot = controlled_mass_flow(p, T_die, dT_die, integral_error)
    dT_fluid = (q_die_fluid - m_dot * p.cp_J_kgK * (T_fluid - p.T_inlet_C)) / p.C_fluid_J_K

    du[1] = dT_die
    du[2] = dT_fluid
    # Conditional integration prevents the controller winding up against a flow limit.
    error = T_die - p.T_setpoint_C
    unsaturated = p.m_dot_min_kg_s < p.m_dot_nominal_kg_s + p.Kp_kg_s_K * error +
                  p.Kd_kg_s_s_K * dT_die + p.Ki_kg_s_K_s * integral_error < p.m_dot_max_kg_s
    du[3] = (unsaturated || (m_dot == p.m_dot_min_kg_s && error > 0) ||
             (m_dot == p.m_dot_max_kg_s && error < 0)) ? error : 0.0
    return nothing
end

"""Solve the coupled thermal and PID states using the Tsitouras 5/4 method."""
function run_simulation(params::SimulationParams, profile::TelemetryProfile)
    validate_params(params)
    context = (params=params, profile=profile)
    u0 = [params.T_die_initial_C, params.T_fluid_initial_C, 0.0]
    problem = ODEProblem(thermal_dynamics!, u0, (profile.time_s[1], profile.time_s[end]), context)
    return solve(problem, Tsit5(); reltol=params.reltol, abstol=params.abstol,
                 saveat=profile.time_s)
end

end # module
