# lanczos.jl
#
# Lanczos iteration for constructing the orthonormal basis of a Krylov subspace.
struct LanczosIterator{F,T,O<:Orthogonalizer}
    operator::F
    v₀::T
    orth::O
    keepvecs::Bool
    function LanczosIterator{F,T,O}(operator::F, v₀::T, orth::O, keepvecs::Bool) where {F,T,O<:Orthogonalizer}
        if !keepvecs && isa(orth, Reorthogonalizer)
            error("Cannot use reorthogonalization without keeping all Krylov vectors")
        end
        new{F,T,O}(operator, v₀, orth, keepvecs)
    end
end
LanczosIterator(operator::F, v₀::T, orth::O = Defaults.orth, keepvecs::Bool = true) where {F,T,O<:Orthogonalizer} = LanczosIterator{F,T,O}(operator, v₀, orth, keepvecs)

Base.IteratorSize(::Type{<:LanczosIterator}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{<:LanczosIterator}) = Base.EltypeUnknown()

mutable struct LanczosFact{T, S<:Real} <: KrylovFactorization{T}
    k::Int # current Krylov dimension
    V::OrthonormalBasis{T} # basis of length k
    αs::Vector{S}
    βs::Vector{S}
    r::T
end

Base.length(F::LanczosFact) = F.k
Base.sizehint!(F::LanczosFact, n) = begin
    sizehint!(F.V, n)
    sizehint!(F.αs, n)
    sizehint!(F.βs, n)
    return F
end
Base.eltype(F::LanczosFact) = eltype(typeof(F))
Base.eltype(::Type{<:LanczosFact{<:Any,S}}) where {S} = S

basis(F::LanczosFact) = length(F.V) == F.k ? F.V : error("Not keeping vectors during Lanczos factorization")
rayleighquotient(F::LanczosFact) = SymTridiagonal(F.αs, F.βs)
@inbounds normres(F::LanczosFact) = F.βs[F.k]
residual(F::LanczosFact) = F.r

function Base.iterate(iter::LanczosIterator)
    state = initialize(iter)
    value = (basis(state), rayleighquotient(state), residual(state))
    return value, state
end
function Base.iterate(iter::LanczosIterator, state::LanczosFact)
    if normres(state) < eps(real(eltype(state)))
        return nothing
    else
        state = expand!(iter, deepcopy(state))
        value = (basis(state), rayleighquotient(state), residual(state))
        return value, state
    end
end

function initialize(iter::LanczosIterator)
    β₀ = norm(iter.v₀)
    T = typeof(one(eltype(iter.v₀))/β₀) # division might change eltype
    v₀ = mul!(similar(iter.v₀, T), iter.v₀, 1/β₀)
    w = apply(iter.operator, v₀) # applying the operator might change eltype
    v = copyto!(similar(w), v₀)
    r, α = orthogonalize!(w, v, iter.orth)
    β = norm(r)
    n = hypot(α,2*β)
    imag(α) <= sqrt(max(eps(n),eps(one(n)))) || error("operator does not appear to be hermitian: $(imag(α)) vs $n")

    V = OrthonormalBasis([v])
    S = eltype(β)
    αs = [real(α)]
    βs = [β]

    return LanczosFact(1, V, αs, βs, r)
end
function initialize!(iter::LanczosIterator, state::LanczosFact)
    v₀ = iter.v₀
    V = state.V
    while length(V) > 1
        pop!(V)
    end
    αs = empty!(state.αs)
    βs = empty!(state.βs)

    v = mul!(V[1], v₀, 1/norm(v₀))
    w = apply(iter.operator, v)
    r, α = orthogonalize!(w, v, iter.orth)
    β = norm(r)
    n = hypot(α,β)
    imag(α) <= sqrt(max(eps(n),eps(one(n)))) || error("operator does not appear to be hermitian: $(imag(α)) vs $n")

    state.k = 1
    push!(αs, real(α))
    push!(βs, β)
    state.r = r
    return state
end
function expand!(iter::LanczosIterator, state::LanczosFact)
    βold = normres(state)
    V = state.V
    r = state.r
    V = push!(V, rmul!(r, 1/βold))
    r, α, β = lanczosrecurrence(iter.operator, V, βold, iter.orth)
    n = hypot(α, β, βold)
    imag(α) <= sqrt(max(eps(n),eps(one(n)))) || error("operator does not appear to be hermitian: $(imag(α)) vs $n")

    αs = push!(state.αs, real(α))
    βs = push!(state.βs, β)

    !iter.keepvecs && shift!(state.V) # remove oldest V if not keepvecs

    state.k += 1
    state.r = r

    return state
end
function shrink!(state::LanczosFact, k)
    length(state) == length(state.V) || error("we cannot shrink LanczosFact without keeping Lanczos vectors")
    length(state) <= k && return state
    V = state.V
    while length(V) > k+1
        pop!(V)
    end
    r = pop!(V)
    resize!(state.αs, k)
    resize!(state.βs, k)
    state.k = k
    state.r = rmul!(r, normres(state))
    return state
end

# Exploit hermiticity to "simplify" orthonormalization process:
# Lanczos three-term recurrence relation
function lanczosrecurrence(operator, V::OrthonormalBasis, β, orth::Union{ClassicalGramSchmidt,ModifiedGramSchmidt})
    v = V[end]
    w = apply(operator, v)
    w = axpy!( -β, V[end-1], w)

    w, α = orthogonalize!(w, v, orth)
    β = norm(w)
    return w, α, β
end
function lanczosrecurrence(operator, V::OrthonormalBasis, β, orth::ClassicalGramSchmidt2)
    v = V[end]
    w = apply(operator, v)
    w = axpy!( -β, V[end-1], w)

    w, α = orthogonalize!(w, v, ClassicalGramSchmidt())
    w, s = orthogonalize!(w, V, ClassicalGramSchmidt())
    α += s[end]
    β = norm(w)
    return w, α, β
end
function lanczosrecurrence(operator, V::OrthonormalBasis, β, orth::ModifiedGramSchmidt2)
    v = V[end]
    w = apply(operator, v)
    w = axpy!( -β, V[end-1], w)

    w, α = orthogonalize!(w, v, ModifiedGramSchmidt())

    s = α
    for q in V
        w, s = orthogonalize!(w, q, ModifiedGramSchmidt())
    end
    α += s
    β = norm(w)
    return w, α, β
end
function lanczosrecurrence(operator, V::OrthonormalBasis, β, orth::ClassicalGramSchmidtIR)
    v = V[end]
    w = apply(operator, v)
    w = axpy!( -β, V[end-1], w)

    w, α = orthogonalize!(w, v, ClassicalGramSchmidt())
    ab2 = abs2(α) + abs2(β)
    β = norm(w)
    nold = sqrt(abs2(β)+ab2)
    while β < orth.η * nold
        nold = β
        w, s = orthogonalize!(w, V, ClassicalGramSchmidt())
        α += s[end]
        β = norm(w)
    end
    return w, α, β
end
function lanczosrecurrence(operator, V::OrthonormalBasis, β, orth::ModifiedGramSchmidtIR)
    v = V[end]
    w = apply(operator, v)
    w = axpy!( -β, V[end-1], w)

    w, α = orthogonalize!(w, v, ModifiedGramSchmidt())
    ab2 = abs2(α) + abs2(β)
    β = norm(w)
    nold = sqrt(abs2(β)+ab2)
    while β < orth.η * nold
        nold = β
        s = zero(α)
        for q in V
            w, s = orthogonalize!(w, q, ModifiedGramSchmidt())
        end
        α += s
        β = norm(w)
    end
    return w, α, β
end
