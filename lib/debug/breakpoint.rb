# frozen_string_literal: true

require_relative 'color'

module DEBUGGER__
  class Breakpoint
    attr_reader :key

    def initialize do_enable = true
      @deleted = false

      setup
      enable if do_enable
    end

    def safe_eval b, expr
      b.eval(expr)
    rescue Exception => e
      puts "[EVAL ERROR]"
      puts "  expr: #{expr}"
      puts "  err: #{e} (#{e.class})"
      puts "Error caused by #{self}."
      nil
    end

    def setup
      raise "not implemented..."
    end

    def enable
      @tp.enable
    end

    def disable
      @tp&.disable
    end

    def enabled?
      @tp.enabled?
    end

    def delete
      disable
      @deleted = true
    end

    def deleted?
      @deleted
    end

    def suspend
      if @command
        provider, pre_cmds, do_cmds = @command
        nonstop = true if do_cmds
        cmds = [*pre_cmds&.split(';;'), *do_cmds&.split(';;')]
        SESSION.add_preset_commands provider, cmds, kick: false, continue: nonstop
      end

      ThreadClient.current.on_breakpoint @tp, self
    end

    def to_s
      s = ''.dup
      s << " if: #{@cond}"        if defined?(@cond) && @cond
      s << " pre: #{@command[1]}" if defined?(@command) && @command && @command[1]
      s << " do: #{@command[2]}"  if defined?(@command) && @command && @command[2]
      s
    end

    def description
      to_s
    end

    def duplicable?
      false
    end

    include Color

    def generate_label(name)
      colorize(" BP - #{name} ", [:YELLOW, :BOLD, :REVERSE])
    end
  end

  class LineBreakpoint < Breakpoint
    attr_reader :path, :line, :iseq

    def initialize path, line, cond: nil, oneshot: false, hook_call: true, command: nil
      @path = path
      @line = line
      @cond = cond
      @oneshot = oneshot
      @hook_call = hook_call
      @command = command
      @pending = false

      @iseq = nil
      @type = nil

      @key = [@path, @line].freeze

      super()

      try_activate
      @pending = !@iseq
    end

    def setup
      return unless @type

      @tp = TracePoint.new(@type) do |tp|
        if @cond
          next unless safe_eval tp.binding, @cond
        end
        delete if @oneshot

        suspend
      end
    end

    def enable
      return unless @iseq

      if @type == :line
        @tp.enable(target: @iseq, target_line: @line)
      else
        @tp.enable(target: @iseq)
      end

    rescue ArgumentError
      puts @iseq.disasm # for debug
      raise
    end

    def activate iseq, event, line
      @iseq = iseq
      @type = event
      @line = line
      @path = iseq.absolute_path

      @key = [@path, @line].freeze
      SESSION.rehash_bps
      setup
      enable

      if @pending && !@oneshot
        DEBUGGER__.warn "#{self} is activated."
      end
    end

    def activate_exact iseq, events, line
      case
      when events.include?(:RUBY_EVENT_CALL)
        # "def foo" line set bp on the beginning of method foo
        activate(iseq, :call, line)
      when events.include?(:RUBY_EVENT_LINE)
        activate(iseq, :line, line)
      when events.include?(:RUBY_EVENT_RETURN)
        activate(iseq, :return, line)
      when events.include?(:RUBY_EVENT_B_RETURN)
        activate(iseq, :b_return, line)
      when events.include?(:RUBY_EVENT_END)
        activate(iseq, :end, line)
      else
        # not actiavated
      end
    end

    def duplicable?
      @oneshot
    end

    NearestISeq = Struct.new(:iseq, :line, :events)

    def try_activate
      nearest = nil # NearestISeq

      ObjectSpace.each_iseq{|iseq|
        if (iseq.absolute_path || iseq.path) == self.path &&
            iseq.first_lineno <= self.line &&
            iseq.type != :ensure # ensure iseq is copied (duplicated)

          iseq.traceable_lines_norec(line_events = {})
          lines = line_events.keys.sort

          if !lines.empty? && lines.last >= line
            nline = lines.bsearch{|l| line <= l}
            events = line_events[nline]

            next if events == [:RUBY_EVENT_B_CALL]

            if @hook_call &&
               events.include?(:RUBY_EVENT_CALL) &&
               self.line == iseq.first_lineno
              nline = iseq.first_lineno
            end

            if !nearest || ((line - nline).abs < (line - nearest.line).abs)
              nearest = NearestISeq.new(iseq, nline, events)
            else
              if @hook_call && nearest.iseq.first_lineno <= iseq.first_lineno
                if (nearest.line > line && !nearest.events.include?(:RUBY_EVENT_CALL)) ||
                   (events.include?(:RUBY_EVENT_CALL))
                  nearest = NearestISeq.new(iseq, nline, events)
                end
              end
            end
          end
        end
      }

      if nearest
        activate_exact nearest.iseq, nearest.events, nearest.line
      end
    end

    def to_s
      oneshot = @oneshot ? " (oneshot)" : ""

      if @iseq
        "#{generate_label("Line")} #{@path}:#{@line} (#{@type})#{oneshot}" + super
      else
        "#{generate_label("Line (pending)")} #{@path}:#{@line}#{oneshot}" + super
      end
    end

    def inspect
      "<#{self.class.name} #{self.to_s}>"
    end
  end

  class CatchBreakpoint < Breakpoint
    attr_reader :last_exc

    def initialize pat
      @pat = pat.freeze
      @key = [:catch, @pat].freeze
      @last_exc = nil

      super()
    end

    def setup
      @tp = TracePoint.new(:raise){|tp|
        exc = tp.raised_exception
        next if SystemExit === exc
        should_suspend = false

        exc.class.ancestors.each{|cls|
          if @pat === cls.name
            should_suspend = true
            @last_exc = exc
            break
          end
        }
        suspend if should_suspend
      }
    end

    def to_s
      "#{generate_label("Catch")} #{@pat.inspect}"
    end

    def description
      "#{@last_exc.inspect} is raised."
    end
  end

  class CheckBreakpoint < Breakpoint
    def initialize expr
      @expr = expr.freeze
      @key = [:check, @expr].freeze

      super()
    end

    def setup
      @tp = TracePoint.new(:line){|tp|
        next if tp.path.start_with? __dir__
        next if tp.path.start_with? '<internal:'
        # Skip when `JSON.generate` is called during tests
        next if tp.defined_class.to_s == '#<Class:JSON>' and ENV['RUBY_DEBUG_TEST_MODE']

        if safe_eval tp.binding, @expr
          suspend
        end
      }
    end

    def to_s
      "#{generate_label("Check")} #{@expr}"
    end
  end

  class WatchIVarBreakpoint < Breakpoint
    def initialize ivar, object, current
      @ivar = ivar.to_sym
      @object = object
      @key = [:watch, @ivar].freeze

      @current = current
      super()
    end

    def watch_eval
      result = @object.instance_variable_get(@ivar)
      if result != @current
        begin
          @prev = @current
          @current = result
          suspend
        ensure
          remove_instance_variable(:@prev)
        end
      end
    rescue Exception
      false
    end

    def setup
      @tp = TracePoint.new(:line, :return, :b_return){|tp|
        next if tp.path.start_with? __dir__
        next if tp.path.start_with? '<internal:'

        watch_eval
      }
    end

    def to_s
      value_str =
        if defined?(@prev)
          "#{@prev} -> #{@current}"
        else
          "#{@current}"
        end
      "#{generate_label("Watch")} #{@object} #{@ivar} = #{value_str}"
    end
  end

  class MethodBreakpoint < Breakpoint
    attr_reader :sig_method_name, :method

    def initialize b, klass_name, op, method_name, cond, command: nil
      @sig_klass_name = klass_name
      @sig_op = op
      @sig_method_name = method_name
      @klass_eval_binding = b

      @klass = nil
      @method = nil
      @cond = cond
      @command = command
      @key = "#{klass_name}#{op}#{method_name}".freeze

      super(false)
    end

    def setup
      if @cond
        @tp = TracePoint.new(:call){|tp|
          next unless safe_eval tp.binding, @cond
          suspend
        }
      else
        @tp = TracePoint.new(:call){|tp|
          suspend
        }
      end
    end

    def eval_class_name
      return @klass if @klass
      @klass = @klass_eval_binding.eval(@sig_klass_name)
      @klass_eval_binding = nil
      @klass
    end

    def search_method
      case @sig_op
      when '.'
        @method = @klass.method(@sig_method_name)
      when '#'
        @method = @klass.instance_method(@sig_method_name)
      else
        raise "Unknown op: #{@sig_op}"
      end
    end

    def enable
      try_enable
    end

    def try_enable added: false
      eval_class_name
      search_method

      begin
        retried = false
        @tp.enable(target: @method)
        DEBUGGER__.warn "#{self} is activated." if added

      rescue ArgumentError
        raise if retried
        retried = true
        sig_method_name = @sig_method_name

        # maybe C method
        @klass.module_eval do
          orig_name = sig_method_name + '__orig__'
          alias_method orig_name, sig_method_name
          define_method(sig_method_name) do |*args|
            send(orig_name, *args)
          end
        end

        # re-collect the method object after the above patch
        search_method
        retry
      end
    rescue Exception
      raise unless added
    end

    def sig
      @key
    end

    def to_s
      if @method
        "#{generate_label("Method")} #{sig} at #{@method.source_location.join(':')}"
      else
        "#{generate_label("Method (pending)")} #{sig}"
      end + super
    end
  end
end
