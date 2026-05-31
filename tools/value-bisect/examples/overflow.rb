# Silent miscompile demo: a value that Spinel's inference keeps as a 64-bit
# mrb_int (left-shift doesn't trigger Bigint promotion the way doubling does).
#
# Under CRuby, `x` promotes to arbitrary precision and keeps growing. Under
# Spinel with --int-overflow=wrap, `x` is a 64-bit int that silently wraps
# (and goes negative) once it passes bit 62 — no error, just a wrong value.
# The harness pinpoints the exact iteration/line where the two `x` part ways.
x = 1
i = 0
while i < 70
  x = x << 1
  i = i + 1
end
puts x
