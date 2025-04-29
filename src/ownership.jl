
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
            #@show typ movedtype z_prefix z_typename
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
                # weiiiird case???? only liveliness
            end
            if !isnothing(dlsym(lzc, Symbol("$(z_prefix)_$(z_typename)_take"); throw_error=false))
                loanfunc = getfield(LibZenohC, Symbol("$(z_prefix)_$(z_typename)_take"))
                push!(dfns, quote _take(x::Ref{$typ}, y::Ref{$movedtype}) = ($loanfunc)(x, y) end)
            elseif !isnothing(dlsym(lzc, Symbol("$(z_prefix)_internal_$(z_typename)_null"); throw_error=false))
                loanfunc = getfield(LibZenohC, Symbol("$(z_prefix)_internal_$(z_typename)_null"))
                push!(dfns, quote function _take(x::Ref{$typ}, y::Ref{$movedtype})
                    x[] = y[]
                    ($loanfunc)(x)
                end end)
            else 
                # weiiiird case???? only liveliness
            end
        end
    end
    eval(quote $(dfns...) end)
end
