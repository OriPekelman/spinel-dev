# A string divergence downstream of a scalar one. Under --int-overflow=wrap,
# `x` overflows (mrb_int) while CRuby promotes; then `s = x.to_s` turns that
# wrong number into a wrong *string*. The harness now compares string locals,
# so it reports both the int divergence (root cause) and the string one.
x = 1
i = 0
while i < 70
  x = x << 1
  i = i + 1
end
s = x.to_s
label = "result=" + s
puts label
