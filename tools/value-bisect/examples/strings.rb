# Exercises string locals: concat, slicing, upcase, repetition. All within
# Spinel's supported string subset, so CRuby and Spinel must agree — and the
# harness now compares string values, not just scalars.
s = "hello"
t = s + " world"
u = t.upcase
head = t[0, 5]
rep = "ab" * 3
n = t.length
puts u
puts head
puts rep
puts n
