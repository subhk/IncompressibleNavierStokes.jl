"""
    AbstractODEMethod

Abstract ODE method.
"""
abstract type AbstractODEMethod{T} end

"""
    AdamsBashforthCrankNicolsonMethod(; α₁ = 3 // 2, α₂ = -1 // 2, θ = 1 // 2)

IMEX AB-CN: Adams-Bashforth for explicit convection (parameters `α₁` and `α₂`) and
Crank-Nicolson for implicit diffusion (implicitness `θ`).
The method is second order for `θ = 1/2`.
"""
Base.@kwdef struct AdamsBashforthCrankNicolsonMethod{T} <: AbstractODEMethod{T}
    α₁::T = 3 // 2
    α₂::T = -1 // 2
    θ::T = 1 // 2
end

"""
    OneLegMethod(β = 1 // 2)

Explicit one-leg β-method.
"""
Base.@kwdef struct OneLegMethod{T} <: AbstractODEMethod{T}
    β::T = 1 // 2
end

"""
    AbstractRungeKuttaMethod

Abstract Runge Kutta method.
"""
abstract type AbstractRungeKuttaMethod{T} <: AbstractODEMethod{T} end

"""
    ExplicitRungeKuttaMethod(A, b, c, r)

Explicit Runge Kutta method.
"""
struct ExplicitRungeKuttaMethod{T} <: AbstractRungeKuttaMethod{T}
    A::Matrix{T}
    b::Vector{T}
    c::Vector{T}
    r::T
end

"""
    ImplicitRungeKuttaMethod(A, b, c, r; newton_type = :full, maxiter = 10)

Implicit Runge Kutta method.

The implicit linear system is solved at each time step using Newton's method. The
`newton_type` may be one of the following:

- `:no`: Replace iteration matrix with I/Δt (no Jacobian)
- `:approximate`: Build Jacobian once before iterations only
- `:full`: Build Jacobian at each iteration
"""
Base.@kwdef struct ImplicitRungeKuttaMethod{T} <: AbstractRungeKuttaMethod{T}
    A::Matrix{T}
    b::Vector{T}
    c::Vector{T}
    r::T
    newton_type::Symbol = :full
    maxiter::Int = 10
    abstol::T = 1e-14
    reltol::T = 1e-14
end

"""
    runge_kutta_method(A, b, c, r)

Get Runge Kutta method. The function checks whether the method is explicit.
"""
function runge_kutta_method(A, b, c, r; kwargs...)
    s = size(A, 1)
    s == size(A, 2) == length(b) == length(c) || error("A, b, and c must have the same sizes")
    isexplicit = all(≈(0), UpperTriangular(A))
    # T = promote_type(eltype(A), eltype(b), eltype(c), typeof(r)) 
    # TODO: Find where to pass T
    T = Float64
    A = convert(Matrix{T}, A)
    b = convert(Vector{T}, b)
    c = convert(Vector{T}, c)
    r = convert(T, r)
    if isexplicit
        ExplicitRungeKuttaMethod(A, b, c, r; kwargs...)
    else
        ImplicitRungeKuttaMethod(; A, b, c, r, kwargs...)
    end
end

