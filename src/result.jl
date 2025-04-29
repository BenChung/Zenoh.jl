struct ZenohError <: Exception 
    code::LibZenohC.z_result_t
end


function _handle_result(z::LibZenohC.z_result_t)
    if z == LibZenohC.Z_OK
        return
    end
    throw(ZenohError(z))
end


