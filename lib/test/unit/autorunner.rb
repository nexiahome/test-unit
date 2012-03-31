require 'test/unit/color-scheme'
require 'optparse'

module Test
  module Unit
    class AutoRunner
      RUNNERS = {}
      COLLECTORS = {}
      ADDITIONAL_OPTIONS = []
      PREPARE_HOOKS = []

      class << self
        def register_runner(id, runner_builder=Proc.new)
          RUNNERS[id] = runner_builder
          RUNNERS[id.to_s] = runner_builder
        end

        def runner(id)
          RUNNERS[id.to_s]
        end

        @@default_runner = nil
        def default_runner
          runner(@@default_runner)
        end

        def default_runner=(id)
          @@default_runner = id
        end

        def register_collector(id, collector_builder=Proc.new)
          COLLECTORS[id] = collector_builder
          COLLECTORS[id.to_s] = collector_builder
        end

        def collector(id)
          COLLECTORS[id.to_s]
        end

        def register_color_scheme(id, scheme)
          ColorScheme[id] = scheme
        end

        def setup_option(option_builder=Proc.new)
          ADDITIONAL_OPTIONS << option_builder
        end

        def prepare(hook=Proc.new)
          PREPARE_HOOKS << hook
        end

        def run(force_standalone=false, default_dir=nil, argv=ARGV, &block)
          r = new(force_standalone || standalone?, &block)
          r.base = default_dir
          r.prepare
          r.process_args(argv)
          r.run
        end

        def standalone?
          return false unless("-e" == $0)
          ObjectSpace.each_object(Class) do |klass|
            return false if(klass < TestCase)
          end
          true
        end

        @@need_auto_run = true
        def need_auto_run?
          @@need_auto_run
        end

        def need_auto_run=(need)
          @@need_auto_run = need
        end
      end

      register_collector(:descendant) do |auto_runner|
        require 'test/unit/collector/descendant'
        collector = Collector::Descendant.new
        collector.filter = auto_runner.filters
        collector.collect($0.sub(/\.rb\Z/, ''))
      end

      register_collector(:load) do |auto_runner|
        require 'test/unit/collector/load'
        collector = Collector::Load.new
        collector.patterns.concat(auto_runner.pattern) if auto_runner.pattern
        collector.excludes.concat(auto_runner.exclude) if auto_runner.exclude
        collector.base = auto_runner.base
        collector.filter = auto_runner.filters
        collector.collect(*auto_runner.to_run)
      end

      # JUST TEST!
      # register_collector(:xml) do |auto_runner|
      #   require 'test/unit/collector/xml'
      #   collector = Collector::XML.new
      #   collector.filter = auto_runner.filters
      #   collector.collect(auto_runner.to_run[0])
      # end

      # deprecated
      register_collector(:object_space) do |auto_runner|
        require 'test/unit/collector/objectspace'
        c = Collector::ObjectSpace.new
        c.filter = auto_runner.filters
        c.collect($0.sub(/\.rb\Z/, ''))
      end

      # deprecated
      register_collector(:dir) do |auto_runner|
        require 'test/unit/collector/dir'
        c = Collector::Dir.new
        c.filter = auto_runner.filters
        c.pattern.concat(auto_runner.pattern) if auto_runner.pattern
        c.exclude.concat(auto_runner.exclude) if auto_runner.exclude
        c.base = auto_runner.base
        $:.push(auto_runner.base) if auto_runner.base
        c.collect(*(auto_runner.to_run.empty? ? ['.'] : auto_runner.to_run))
      end

      attr_reader :suite, :runner_options
      attr_accessor :filters, :to_run, :pattern, :exclude, :base, :workdir
      attr_accessor :color_scheme, :listeners
      attr_writer :runner, :collector

      def initialize(standalone)
        @standalone = standalone
        @runner = default_runner
        @collector = default_collector
        @filters = []
        @to_run = []
        @color_scheme = ColorScheme.default
        @runner_options = {}
        @default_arguments = []
        @workdir = nil
        @listeners = []
        config_file = "test-unit.yml"
        if File.exist?(config_file)
          load_config(config_file)
        else
          load_global_config
        end
        yield(self) if block_given?
      end

      def prepare
        PREPARE_HOOKS.each do |handler|
          handler.call(self)
        end
      end

      def process_args(args=ARGV)
        args = args.dup
        begin
          args.unshift(*@default_arguments)
          options.order!(args) {|arg| @to_run << arg}
        rescue OptionParser::ParseError => e
          puts e
          puts options
          exit(false)
        end
        not @to_run.empty?
      end

      def options
        @options ||= OptionParser.new do |o|
          o.banner = "Test::Unit automatic runner."
          o.banner << "\nUsage: #{$0} [options] [-- untouched arguments]"

          o.on('-r', '--runner=RUNNER', RUNNERS,
               "Use the given RUNNER.",
               "(" + keyword_display(RUNNERS) + ")") do |r|
            @runner = r
          end

          o.on('--collector=COLLECTOR', COLLECTORS,
               "Use the given COLLECTOR.",
               "(" + keyword_display(COLLECTORS) + ")") do |collector|
            @collector = collector
          end

          if (@standalone)
            o.on('-b', '--basedir=DIR', "Base directory of test suites.") do |b|
              @base = b
            end

            o.on('-w', '--workdir=DIR', "Working directory to run tests.") do |w|
              @workdir = w
            end

            o.on('-a', '--add=TORUN', Array,
                 "Add TORUN to the list of things to run;",
                 "can be a file or a directory.") do |a|
              @to_run.concat(a)
            end

            @pattern = []
            o.on('-p', '--pattern=PATTERN', Regexp,
                 "Match files to collect against PATTERN.") do |e|
              @pattern << e
            end

            @exclude = []
            o.on('-x', '--exclude=PATTERN', Regexp,
                 "Ignore files to collect against PATTERN.") do |e|
              @exclude << e
            end
          end

          o.on('-n', '--name=NAME', String,
               "Runs tests matching NAME.",
               "(patterns may be used).") do |name|
            name = (%r{\A/(.*)/\Z} =~ name ? Regexp.new($1) : name)
            @filters << lambda do |test|
              return true if name === test.method_name
              test_name_without_class_name = test.name.gsub(/\(.+?\)\z/, "")
              if test_name_without_class_name != test.method_name
                return true if name === test_name_without_class_name
              end
              false
            end
          end

          o.on('--ignore-name=NAME', String,
               "Ignores tests matching NAME.",
               "(patterns may be used).") do |n|
            n = (%r{\A/(.*)/\Z} =~ n ? Regexp.new($1) : n)
            case n
            when Regexp
              @filters << proc {|t| n =~ t.method_name ? false : true}
            else
              @filters << proc {|t| n != t.method_name}
            end
          end

          o.on('-t', '--testcase=TESTCASE', String,
               "Runs tests in TestCases matching TESTCASE.",
               "(patterns may be used).") do |n|
            n = (%r{\A/(.*)/\Z} =~ n ? Regexp.new($1) : n)
            case n
            when Regexp
              @filters << proc{|t| n =~ t.class.name ? true : false}
            else
              @filters << proc{|t| n == t.class.name}
            end
          end

          o.on('--ignore-testcase=TESTCASE', String,
               "Ignores tests in TestCases matching TESTCASE.",
               "(patterns may be used).") do |n|
            n = (%r{\A/(.*)/\Z} =~ n ? Regexp.new($1) : n)
            case n
            when Regexp
              @filters << proc {|t| n =~ t.class.name ? false : true}
            else
              @filters << proc {|t| n != t.class.name}
            end
          end

          priority_filter = Proc.new do |test|
            if @filters == [priority_filter]
              Priority::Checker.new(test).need_to_run?
            else
              nil
            end
          end
          o.on("--[no-]priority-mode",
               "Runs some tests based on their priority.") do |priority_mode|
            if priority_mode
              Priority.enable
              @filters |= [priority_filter]
            else
              Priority.disable
              @filters -= [priority_filter]
            end
          end

          o.on("--default-priority=PRIORITY",
               Priority.available_values,
               "Uses PRIORITY as default priority",
               "(#{keyword_display(Priority.available_values)})") do |priority|
            Priority.default = priority
          end

          o.on('-I', "--load-path=DIR[#{File::PATH_SEPARATOR}DIR...]",
               "Appends directory list to $LOAD_PATH.") do |dirs|
            $LOAD_PATH.concat(dirs.split(File::PATH_SEPARATOR))
          end

          color_schemes = ColorScheme.all
          o.on("--color-scheme=SCHEME", color_schemes,
               "Use SCHEME as color scheme.",
               "(#{keyword_display(color_schemes)})") do |scheme|
            @color_scheme = scheme
          end

          o.on("--config=FILE",
               "Use YAML fomat FILE content as configuration file.") do |file|
            load_config(file)
          end

          o.on("--order=ORDER", TestCase::AVAILABLE_ORDERS,
               "Run tests in a test case in ORDER order.",
               "(#{keyword_display(TestCase::AVAILABLE_ORDERS)})") do |order|
            TestCase.test_order = order
          end

          assertion_message_class = Test::Unit::Assertions::AssertionMessage
          o.on("--max-diff-target-string-size=SIZE", Integer,
               "Shows diff if both expected result string size and " +
               "actual result string size are " +
               "less than or equal SIZE in bytes.",
               "(#{assertion_message_class.max_diff_target_string_size})") do |size|
            assertion_message_class.max_diff_target_string_size = size
          end

          ADDITIONAL_OPTIONS.each do |option_builder|
            option_builder.call(self, o)
          end

          o.on('--',
               "Stop processing options so that the",
               "remaining options will be passed to the",
               "test."){o.terminate}

          o.on('-h', '--help', 'Display this help.'){puts o; exit}

          o.on_tail
          o.on_tail('Deprecated options:')

          o.on_tail('--console', 'Console runner (use --runner).') do
            warn("Deprecated option (--console).")
            @runner = self.class.runner(:console)
          end

          if RUNNERS[:fox]
            o.on_tail('--fox', 'Fox runner (use --runner).') do
              warn("Deprecated option (--fox).")
              @runner = self.class.runner(:fox)
            end
          end

          o.on_tail
        end
      end

      def keyword_display(keywords)
        keywords = keywords.collect do |keyword, _|
          keyword.to_s
        end.uniq.sort

        i = 0
        keywords.collect do |keyword|
          if (i > 0 and keyword[0] == keywords[i - 1][0]) or
              ((i < keywords.size - 1) and (keyword[0] == keywords[i + 1][0]))
            n = 2
          else
            n = 1
          end
          i += 1
          keyword.sub(/^(.{#{n}})([A-Za-z]+)(?=\w*$)/, '\\1[\\2]')
        end.join(", ")
      end

      def run
        self.class.need_auto_run = false
        suite = @collector[self]
        return false if suite.nil?
        return true if suite.empty?
        runner = @runner[self]
        return false if runner.nil?
        @runner_options[:color_scheme] ||= @color_scheme
        @runner_options[:listeners] ||= []
        @runner_options[:listeners].concat(@listeners)
        Dir.chdir(@workdir) if @workdir
        runner.run(suite, @runner_options).passed?
      end

      def load_config(file)
        require 'yaml'
        config = YAML.load(File.read(file))
        runner_name = config["runner"]
        @runner = self.class.runner(runner_name) || @runner
        @collector = self.class.collector(config["collector"]) || @collector
        (config["color_schemes"] || {}).each do |name, options|
          ColorScheme[name] = options
        end
        runner_options = {}
        (config["#{runner_name}_options"] || {}).each do |key, value|
          key = key.to_sym
          value = ColorScheme[value] if key == :color_scheme
          if key == :arguments
            @default_arguments.concat(value.split)
          else
            runner_options[key.to_sym] = value
          end
        end
        @runner_options = @runner_options.merge(runner_options)
      end

      private
      def default_runner
        runner = self.class.default_runner
        if ENV["EMACS"] == "t"
          runner ||= self.class.runner(:emacs)
        else
          runner ||= self.class.runner(:console)
        end
        runner
      end

      def default_collector
        self.class.collector(@standalone ? :load : :descendant)
      end

      def global_config_file
        File.expand_path("~/.test-unit.yml")
      rescue ArgumentError
        nil
      end

      def load_global_config
        file = global_config_file
        load_config(file) if file and File.exist?(file)
      end
    end
  end
end

require 'test/unit/runner/console'
require 'test/unit/runner/emacs'
require 'test/unit/runner/xml'
