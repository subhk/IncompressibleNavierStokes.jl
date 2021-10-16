using IncompressibleNavierStokes
using GLMakie

## Load input parameters and constants
# case_name = "LDC"
case_name = "BFS"
# case_name = "TG"
include("case_files/$case_name.jl")
setup = eval(:($(Symbol(case_name))()));

##
@time V, p, totaltime = main(setup);

##
@profview main(setup)

##

# Turbulence constants
if setup.case.visc == "keps"
    constants_ke!(setup)
end

# Construct mesh
create_mesh!(setup);

# Boundary conditions
create_boundary_conditions!(setup);

# Construct operators (matrices) which are time-independent
build_operators!(setup);

# Initialization of solution vectors
V₀, p₀, t₀ = create_initial_conditions(setup);

# Input checking
check_input!(setup, V₀, p₀, t₀)

# Choose between steady and unsteady
if setup.case.is_steady
    # Steady
    if setup.case.visc == "keps"
        # Steady flow with k-epsilon model, 2nd order
        V, p = solve_steady_ke(setup, V₀, p₀);
    elseif setup.case.visc == "laminar"
        if setup.discretization.order4
            # Steady flow with laminar viscosity model, 4th order
            V, p = solve_steady(setup, V₀, p₀);
        else
            if setup.ibm.ibm
                # Steady flow with laminar viscosity model and immersed boundary method, 2nd order
                V, p = solve_steady_ibm(setup, V₀, p₀);
            else
                # Steady flow with laminar viscosity model, 2nd order
                V, p = solve_steady(setup, V₀, p₀);
            end
        end
    elseif setup.case.visc == "ML"
        # Steady flow with mixing length, 2nd order
        V, p = solve_steady(setup, V₀, p₀);
    else
        error("wrong value for visc parameter")
    end
else
    # Unsteady
    if setup.case.visc == "keps"
        # Unsteady flow with k-eps model, 2nd order
        V, p = solve_unsteady_ke(setup, V₀, p₀);
    elseif setup.case.visc ∈ ["laminar", "qr", "LES", "ML"]
        if setup.rom.use_rom
            # Unsteady flow with reduced order model with $(setup.rom.M) modes
            V, p = solve_unsteady_rom(setup, V₀, p₀);
        else
            # Unsteady flow with laminar or LES model
            V, p = solve_unsteady(setup, V₀, p₀);
        end
    else
        error("wrong value for visc parameter");
    end
end;
totaltime = Base.time() - starttime;

## Post-processing
postprocess(setup, V, p, setup.time.t_end);
plot_pressure(setup, p);
plot_vorticity(setup, V, setup.time.t_end);
plot_streamfunction(setup, V, setup.time.t_end);
