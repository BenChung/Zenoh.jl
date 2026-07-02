
using Libdl

ownedtypes = r"(z[ce]?)_owned_(.*?)_t"
movedtypes = r"(z[ce]?)_moved_(.*?)_t"
loanedtypes = r"(z[ce]?)_loaned_(.*?)_t"
function has_ofreg(z_prefix, z_typename, matcher)
    for typname in names(LibZenohC)
        typ = getfield(LibZenohC, typname)
        if !(typ isa DataType) continue end
        if !contains(String(typname), matcher) continue end
        res = match(matcher, String(typname))
        if z_prefix != res[1] || z_typename != res[2] continue end
        return typ
    end
    return nothing
end

@eval begin 
    lzc = dlopen(LibZenohC.libzenohc)
    dfns = []
    seen = IdSet()
    for typname in names(LibZenohC)
        typ = getfield(LibZenohC, typname)
        if !(typ isa DataType) continue end
        if typ ∈ seen continue end
        push!(seen, typ)
        if !contains(String(typname), ownedtypes) continue end
        mtch = match(ownedtypes, String(typname))
        z_prefix = mtch[1]
        z_typename = mtch[2]
        movedtype = has_ofreg(z_prefix, z_typename, movedtypes)
        loanedtype = has_ofreg(z_prefix, z_typename, loanedtypes)
        if !isnothing(movedtype)
            has_func = !isnothing(dlsym(lzc, Symbol("$(z_prefix)_$(z_typename)_move"); throw_error=false))
            if has_func
                movefunc = getfield(LibZenohC, Symbol("$(z_prefix)_$(z_typename)_move"))
                push!(dfns, quote _move(x::Ref{$typ}) = ($movefunc)(x) end)
            else
                push!(dfns, quote _move(x::Ref{$typ}) = Base.unsafe_convert(Ptr{$movedtype}, Base.unsafe_convert(Ptr{$typ}, x)) end)
            end
        end
        if !isnothing(loanedtype)
            has_func = !isnothing(dlsym(lzc, Symbol("$(z_prefix)_$(z_typename)_loan"); throw_error=false))
            if has_func 
                loanfunc = getfield(LibZenohC, Symbol("$(z_prefix)_$(z_typename)_loan"))
                push!(dfns, quote _loan(x::Ref{$typ}) = ($loanfunc)(x) end)
            else
                push!(dfns, quote _loan(x::Ref{$typ}) = Base.unsafe_convert(Ptr{$loanedtype}, Base.unsafe_convert(Ptr{$typ}, x)) end)
            end
        end
        if !isnothing(dlsym(lzc, Symbol("$(z_prefix)_$(z_typename)_loan_mut"); throw_error=false))
            loanfunc = getfield(LibZenohC, Symbol("$(z_prefix)_$(z_typename)_loan_mut"))
            push!(dfns, quote _loan_mut(x::Ref{$typ}) = ($loanfunc)(x) end)
        end
        if !isnothing(movedtype)
            if !isnothing(dlsym(lzc, Symbol("$(z_prefix)_$(z_typename)_drop"); throw_error=false))
                loanfunc = getfield(LibZenohC, Symbol("$(z_prefix)_$(z_typename)_drop"))
                push!(dfns, quote _drop(x::Ref{$movedtype}) = ($loanfunc)(x) end)
            else
                # No _drop: the non-greedy `ownedtypes` regex truncates *_token_t,
                # so the `z_<name>_drop` lookup misses the real `z_<name>_token_drop`.
                # liveliness and cancellation both land here; both drop via direct C
                # calls (see cancellation.jl), so nothing is needed.
            end
            if !isnothing(dlsym(lzc, Symbol("$(z_prefix)_$(z_typename)_take"); throw_error=false))
                loanfunc = getfield(LibZenohC, Symbol("$(z_prefix)_$(z_typename)_take"))
                push!(dfns, quote _take(x::Ref{$typ}, y::Ref{$movedtype}) = ($loanfunc)(x, y) end)
            elseif !isnothing(dlsym(lzc, Symbol("$(z_prefix)_internal_$(z_typename)_null"); throw_error=false))
                loanfunc = getfield(LibZenohC, Symbol("$(z_prefix)_internal_$(z_typename)_null"))
                # Move-by-hand when `_take` is absent: `z_moved_X_t` and
                # `z_owned_X_t` share a layout, so copy the owned bits from the
                # moved source `y` into destination `x`, then null the source.
                push!(dfns, quote function _take(x::Ref{$typ}, y::Ref{$movedtype})
                    GC.@preserve x y begin
                        yp = Base.unsafe_convert(Ptr{$typ},
                            Base.unsafe_convert(Ptr{$movedtype}, y))
                        Base.unsafe_store!(Base.unsafe_convert(Ptr{$typ}, x),
                            Base.unsafe_load(yp))
                        ($loanfunc)(yp)
                    end
                end end)
            else
                # No _take: same regex truncation as above; `z_<name>_take` and
                # `z_internal_<name>_null` miss the real `z_<name>_token_*` symbols.
            end
        end
    end
    eval(quote $(dfns...) end)
end

# Read a libzenoh-owned z_string into a Julia String. The caller is
# responsible for dropping the owned string afterwards (typical pattern:
# build into a Ref, `_string(ref)`, then `_drop(_move(ref))`).
function _string(r::Ref{LibZenohC.z_owned_string_t})
    return unsafe_string(LibZenohC.z_string_data(_loan(r)), LibZenohC.z_string_len(_loan(r)))
end

# Poke a single field of an options struct through its raw pointer.
#
# Clang.jl skips generating `Base.setproperty!` for gap-free POD option
# structs (z_queryable_options_t, z_querier_options_t, …), and
# reconstructing the struct via its Julia constructor can clobber padding
# bytes libzenohc relies on. So the opts-builders write one field at a
# time at its `fieldoffset`. `val` must already be the field's exact C
# type — the store is by `typeof(val)`, so a Julia `Int` where the field
# is `UInt64` would land the wrong width; convert at the call site (the
# builders do, e.g. `UInt64(timeout_ms)`).
@inline function _store_field!(opts::Ref{T}, idx::Integer, val) where {T}
    p = Base.unsafe_convert(Ptr{T}, opts)
    unsafe_store!(Ptr{typeof(val)}(p + fieldoffset(T, idx)), val)
    return nothing
end
