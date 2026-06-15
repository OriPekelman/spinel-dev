# spinel-dev#13. A poly_array value reaching a concrete int_array
# boundary used to pointer-pun: since the divergent-tuple unification,
# an array literal whose element widened to poly emits sp_PolyArray
# (boxed sp_RbVal slots), while a callee param pinned int_array (e.g.
# by an FFI :int_array spec back-prop) kept its concrete C type — the
# arg temp was emitted as `sp_IntArray *t = <sp_PolyArray *>;` and a
# bulk-FFI consumer then read boxed tags as raw int64s (toy's
# ggml_abort inside tnn_upload_from_int_array). Now both boundaries
# convert: compile_expr_for_expected_type unboxes element-wise into a
# fresh IntArray/FloatArray, and the direct :int_array/:float_array
# FFI lowering routes a poly_array arg through the
# sp_PolyArray_ffi_int_data/_float_data bridge instead of `->data`.
#
# The FFI callee is `ftok` — in libc on both Linux and macOS, declared
# only in <sys/ipc.h> (which the runtime never includes, so the
# :int_array-spec extern doesn't clash), and harmless with these args
# (it stats a short garbage path and returns -1). It exists to make
# the boundary REAL and executed: the poly slots built by the
# heterogeneous multi-return destructure round-trip through the
# conversion and must keep their values on the Ruby side.

module CLib
  ffi_func :ftok, [:int_array, :size_t], :int
end

module Up
  def self.upload(indices)
    x = indices[0]
    CLib.ftok(indices, indices.length)
    x
  end
end

def pair(flag)
  if flag == 0
    return nil, nil
  end
  return 7, 1.5
end

a, b = pair(1)
puts Up.upload([5, 6]).to_s
puts Up.upload([a]).to_s
puts b.to_s
