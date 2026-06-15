# Regression: spinel-dev#14 — an ivar array literal whose element is a
# constructor of a class defined LATER in the program (forward reference
# via source/require order, like tep's App#initialize building
# `[Tep::FiberSlot.new(...)]` before lib/tep.rb defines FiberSlot).
#
# Pass-1 collect_ivars scans the literal before Slot is registered, so
# the `.new` element types as the int fallback (#1305) and the slot is
# pinned int_array (indefinite). The writer-scan then re-infers the same
# write with the full class table as obj_Slot_ptr_array — that is a
# refinement of the placeholder, not a heterogeneous disagreement, and
# must replace int_array rather than widen the slot to poly_array
# (which un-typed every element op: `delete_at` warned "cannot resolve
# on poly_array" and emitted 0, crashing tep at static init).
class Holder
  attr_accessor :slots
  def initialize
    # Seed-then-delete element-type pinning idiom (tep app.rb:120).
    @slots = [Slot.new(0)]
    @slots.delete_at(0)
  end
end

class Slot
  attr_accessor :v
  def initialize(v)
    @v = v
  end
end

h = Holder.new
puts h.slots.length      #=> 0 (seed deleted: delete_at resolved, not emitted 0)
h.slots.push(Slot.new(7))
h.slots.push(Slot.new(9))
puts h.slots[0].v        #=> 7 (typed element: method dispatch works)
h.slots.delete_at(0)
puts h.slots.length      #=> 1
puts h.slots[0].v        #=> 9

# A genuinely heterogeneous pair of DEFINITE array literals must still
# widen (the refinement is gated on the int_array being the indefinite
# Pass-1 placeholder, not a real [int] write).
class Mixed
  def initialize(flag)
    if flag == 1
      @xs = [1, 2]
    else
      @xs = ["a"]
    end
  end
  def n
    @xs.length
  end
end
puts Mixed.new(1).n      #=> 2
puts Mixed.new(0).n      #=> 1
