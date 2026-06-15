# Regression: sequel to uncalled_method_param_callee_backprop (spinel-dev#11) —
# the same uncalled-forwarder hole, but with a *constructor* as the shared
# callee. `UncalledRecipe#go` is never called and forwards `cfg` into
# `Model.new(cfg)`; the callee-slot back-prop only resolved receiver-dispatched
# instance methods, so the param stayed poly/int and mismatched the concrete
# `sp_Cfg` constructor slot (`sp_Cfg` vs `sp_Cfg *`) at the dead-but-emitted
# call. Constructor slots (`Klass.new` -> `Klass#initialize`) must back-prop
# the same way. spinel-dev#12.
class Cfg
  def initialize(v) ; @v = v ; end
  def v ; @v ; end
end

class Model
  def initialize(cfg) ; @label = cfg.v.to_s ; end
  def label ; @label ; end
end

class Engine
  def realize_a(cfg) ; Model.new(cfg) ; end
end

class CalledRecipe
  def go(cfg) ; Engine.new.realize_a(cfg) ; end
end

class UncalledRecipe
  def go(cfg) ; Model.new(cfg) ; end
end

puts CalledRecipe.new.go(Cfg.new(5)).label
