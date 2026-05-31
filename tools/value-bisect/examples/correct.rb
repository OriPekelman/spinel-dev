# Negative control: stays within int64, so CRuby and Spinel must agree on
# every scalar local. The harness should report OK and exit 0.
def fib(n)
  a = 0
  b = 1
  i = 0
  while i < n
    t = a + b
    a = b
    b = t
    i = i + 1
  end
  a
end
puts fib(40)
