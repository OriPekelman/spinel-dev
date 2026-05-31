# Helper: the value that silently overflows lives here, in a separate file.
def shift_left(start, times)
  x = start
  i = 0
  while i < times
    x = x << 1
    i = i + 1
  end
  x
end
