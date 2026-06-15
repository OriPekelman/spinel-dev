# Regression: an *uncalled* instance method's unconstrained param, forwarded into
# a shared instance method, used to keep its `int` default (no call site to
# constrain it, and the callee-slot back-prop covered only top-level methods),
# then mismatched the shared method's concrete C param (`int` vs `sp_Cfg`) and
# broke the C build. `Uncalled#go` is never called; `Engine#realize` is shared
# with the live `Called#go`. spinel-dev#11.
class Cfg
  def initialize(v) ; @v = v ; end
  def v ; @v ; end
end

class Engine
  def realize(cfg)
    cfg.v + 1
  end
end

class Called
  def go(cfg) ; Engine.new.realize(cfg) ; end
end

class Uncalled
  def go(cfg) ; Engine.new.realize(cfg) ; end
end

c = Cfg.new(5)
puts Called.new.go(c).to_s
