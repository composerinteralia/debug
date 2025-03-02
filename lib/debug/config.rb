# frozen_string_literal: true

module DEBUGGER__
  def self.unix_domain_socket_dir
    case
    when path = ::DEBUGGER__::CONFIG[:sock_dir]
    when path = ENV['XDG_RUNTIME_DIR']
    when home = ENV['HOME']
      path = File.join(home, '.ruby-debug-sock')

      case
      when !File.exist?(path)
        Dir.mkdir(path, 0700)
      when !File.directory?(path)
        raise "#{path} is not a directory."
      end
    else
      raise 'specify RUBY_DEBUG_SOCK_DIR environment variable for UNIX domain socket directory.'
    end

    path
  end

  def self.create_unix_domain_socket_name_prefix(base_dir = unix_domain_socket_dir)
    user = ENV['USER'] || 'ruby-debug'
    File.join(base_dir, "ruby-debug-#{user}")
  end

  def self.create_unix_domain_socket_name(base_dir = unix_domain_socket_dir)
    create_unix_domain_socket_name_prefix(base_dir) + "-#{Process.pid}"
  end

  CONFIG_SET = {
    # UI setting
    log_level:      ['RUBY_DEBUG_LOG_LEVEL',      "UI: Log level same as Logger (default: WARN)",                   :loglevel],
    show_src_lines: ['RUBY_DEBUG_SHOW_SRC_LINES', "UI: Show n lines source code on breakpoint (default: 10 lines)", :int],
    show_frames:    ['RUBY_DEBUG_SHOW_FRAMES',    "UI: Show n frames on breakpoint (default: 2 frames)",            :int],
    show_info_lines:['RUBY_DEBUG_SHOW_INFO_LINES',"UI: Show n lines on info command (default: 10 lines, 0 for unlimited)",   :int],
    use_short_path: ['RUBY_DEBUG_USE_SHORT_PATH', "UI: Show shoten PATH (like $(Gem)/foo.rb)",                      :bool],
    skip_nosrc:     ['RUBY_DEBUG_SKIP_NOSRC',     "UI: Skip on no source code lines (default: false)",              :bool],
    skip_path:      ['RUBY_DEBUG_SKIP_PATH',      "UI: Skip showing frames for given paths (default: [])",          :path],
    no_color:       ['RUBY_DEBUG_NO_COLOR',       "UI: Do not use colorize (default: false)",                       :bool],
    no_sigint_hook: ['RUBY_DEBUG_NO_SIGINT_HOOK', "UI: Do not suspend on SIGINT (default: false)",                  :bool],

    # boot setting
    nonstop:        ['RUBY_DEBUG_NONSTOP',     "BOOT: Nonstop mode",                                                :bool],
    init_script:    ['RUBY_DEBUG_INIT_SCRIPT', "BOOT: debug command script path loaded at first stop"],
    commands:       ['RUBY_DEBUG_COMMANDS',    "BOOT: debug commands invoked at first stop. commands should be separated by ';;'"],
    no_rc:          ['RUBY_DEBUG_NO_RC',       "BOOT: ignore loading ~/.rdbgrc(.rb)",                               :bool],

    # remote setting
    port:           ['RUBY_DEBUG_PORT',      "REMOTE: TCP/IP remote debugging: port"],
    host:           ['RUBY_DEBUG_HOST',      "REMOTE: TCP/IP remote debugging: host (localhost if not given)"],
    sock_path:      ['RUBY_DEBUG_SOCK_PATH', "REMOTE: UNIX Domain Socket remote debugging: socket path"],
    sock_dir:       ['RUBY_DEBUG_SOCK_DIR',  "REMOTE: UNIX Domain Socket remote debugging: socket directory"],
    cookie:         ['RUBY_DEBUG_COOKIE',    "REMOTE: Cookie for negotiation"],
  }.freeze

  CONFIG_MAP = CONFIG_SET.map{|k, (ev, desc)| [k, ev]}.to_h.freeze

  def self.config_to_env_hash config
    CONFIG_MAP.each_with_object({}){|(key, evname), env|
      env[evname] = config[key].to_s if config[key]
    }
  end

  def self.parse_config_value name, valstr
    return valstr unless valstr.kind_of? String

    case CONFIG_SET[name][2]
    when :bool
      case valstr
      when '1', 'true', 'TRUE', 'T'
        true
      else
        false
      end
    when :int
      valstr.to_i
    when :loglevel
      if DEBUGGER__::LOG_LEVELS[s = valstr.to_sym]
        s
      else
        raise "Unknown loglevel: #{valstr}"
      end
    when :path # array of String
      valstr.split(/:/).map{|e|
        if /\A\/(.+)\/\z/ =~ e
          Regexp.compile $1
        else
          e
        end
      }
    else
      valstr
    end
  end

  def self.parse_argv argv
    config = {
      mode: :start,
    }
    CONFIG_MAP.each{|key, evname|
      if val = ENV[evname]
        config[key] = parse_config_value(key, val)
      end
    }
    return config if !argv || argv.empty?

    require 'optparse'
    require_relative 'version'

    opt = OptionParser.new do |o|
      o.banner = "#{$0} [options] -- [debuggee options]"
      o.separator ''
      o.version = ::DEBUGGER__::VERSION

      o.separator 'Debug console mode:'
      o.on('-n', '--nonstop', 'Do not stop at the beginning of the script.') do
        config[:nonstop] = '1'
      end

      o.on('-e DEBUG_COMMAND', 'Execute debug command at the beginning of the script.') do |cmd|
        config[:commands] ||= ''
        config[:commands] += cmd + ';;'
      end

      o.on('-x FILE', '--init-script=FILE', 'Execute debug command in the FILE.') do |file|
        config[:init_script] = file
      end
      o.on('--no-rc', 'Ignore ~/.rdbgrc') do
        config[:no_rc] = true
      end
      o.on('--no-color', 'Disable colorize') do
        config[:no_color] = true
      end

      o.on('-c', '--command', 'Enable command mode.',
                              'The first argument should be a command name in $PATH.',
                              'Example: \'rdbg -c bundle exec rake test\'') do
        config[:command] = true
      end

      o.separator ''

      o.on('-O', '--open', 'Start remote debugging with opening the network port.',
                           'If TCP/IP options are not given,',
                           'a UNIX domain socket will be used.') do
        config[:remote] = true
      end
      o.on('--sock-path=SOCK_PATH', 'UNIX Doman socket path') do |path|
        config[:sock_path] = path
      end
      o.on('--port=PORT', 'Listening TCP/IP port') do |port|
        config[:port] = port
      end
      o.on('--host=HOST', 'Listening TCP/IP host') do |host|
        config[:host] = host
      end
      o.on('--cookie=COOKIE', 'Set a cookie for connection') do |c|
        config[:cookie] = c
      end

      rdbg = 'rdbg'

      o.separator ''
      o.separator '  Debug console mode runs Ruby program with the debug console.'
      o.separator ''
      o.separator "  '#{rdbg} target.rb foo bar'                starts like 'ruby target.rb foo bar'."
      o.separator "  '#{rdbg} -- -r foo -e bar'                 starts like 'ruby -r foo -e bar'."
      o.separator "  '#{rdbg} -c rake test'                     starts like 'rake test'."
      o.separator "  '#{rdbg} -c -- rake test -t'               starts like 'rake test -t'."
      o.separator "  '#{rdbg} -c bundle exec rake test'         starts like 'bundle exec rake test'."
      o.separator "  '#{rdbg} -O target.rb foo bar'             starts and accepts attaching with UNIX domain socket."
      o.separator "  '#{rdbg} -O --port 1234 target.rb foo bar' starts accepts attaching with TCP/IP localhost:1234."
      o.separator "  '#{rdbg} -O --port 1234 -- -r foo -e bar'  starts accepts attaching with TCP/IP localhost:1234."

      o.separator ''
      o.separator 'Attach mode:'
      o.on('-A', '--attach', 'Attach to debuggee process.') do
        config[:mode] = :attach
      end

      o.separator ''
      o.separator '  Attach mode attaches the remote debug console to the debuggee process.'
      o.separator ''
      o.separator "  '#{rdbg} -A'           tries to connect via UNIX domain socket."
      o.separator "  #{' ' * rdbg.size}                If there are multiple processes are waiting for the"
      o.separator "  #{' ' * rdbg.size}                debugger connection, list possible debuggee names."
      o.separator "  '#{rdbg} -A path'      tries to connect via UNIX domain socket with given path name."
      o.separator "  '#{rdbg} -A port'      tries to connect to localhost:port via TCP/IP."
      o.separator "  '#{rdbg} -A host port' tries to connect to host:port via TCP/IP."

      o.separator ''
      o.separator 'Other options:'

      o.on("-h", "--help", "Print help") do
        puts o
        exit
      end

      o.on('--util=NAME', 'Utility mode (used by tools)') do |name|
        require_relative 'client'
        Client.new(name)
        exit
      end

      o.separator ''
      o.separator 'NOTE'
      o.separator '  All messages communicated between a debugger and a debuggee are *NOT* encrypted.'
      o.separator '  Please use the remote debugging feature carefully.'
    end

    opt.parse!(argv)

    config
  end

  CONFIG = ::DEBUGGER__.parse_argv(ENV['RUBY_DEBUG_OPT'])

  def self.set_config kw
    kw.each{|k, v|
      if CONFIG_MAP[k]
        CONFIG[k] = parse_config_value(k, v) # TODO: ractor support
      else
        raise "Unknown configuration: #{k}"
      end
    }
  end

  def self.append_config key, val
    if CONFIG_SET[key]
      if CONFIG_SET[key][2] == :path
        CONFIG[key] = [*CONFIG[key], *parse_config_value(key, val)];
      else
        raise "not an Array type: #{key}"
      end
    else
      raise "Unknown configuration: #{key}"
    end
  end
end
