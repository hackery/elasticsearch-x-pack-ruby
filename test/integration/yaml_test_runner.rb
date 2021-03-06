RUBY_1_8 = defined?(RUBY_VERSION) && RUBY_VERSION < '1.9'
JRUBY    = defined?(JRUBY_VERSION)

require 'pathname'
require 'logger'
require 'yaml'
require 'active_support/inflector'
require 'ansi'

require 'elasticsearch'
require 'elasticsearch/extensions/test/cluster'
require 'elasticsearch/extensions/test/startup_shutdown'
require 'elasticsearch/extensions/test/profiling' unless JRUBY

# Skip features
skip_features = 'stash_in_path,requires_replica'
SKIP_FEATURES = ENV.fetch('TEST_SKIP_FEATURES', skip_features)

# Launch test cluster
#
if ENV['SERVER'] and not Elasticsearch::Extensions::Test::Cluster.running?
  es_params = "-D es.repositories.url.allowed_urls=http://snapshot.test* -D es.path.repo=/tmp -D es.node.testattr=test " + ENV['TEST_CLUSTER_PARAMS'].to_s
  Elasticsearch::Extensions::Test::Cluster.start(nodes: 1, es_params: es_params )
end

# Register `at_exit` handler for server shutdown.
# MUST be called before requiring `test/unit`.
#
at_exit { Elasticsearch::Extensions::Test::Cluster.stop if ENV['SERVER'] and Elasticsearch::Extensions::Test::Cluster.running? }

class String
  # Reset the `ansi` method on CI
  def ansi(*args)
    self
  end
end if ENV['CI']

module CapturedLogger
  def self.included base
    base.class_eval do
      %w[ info error warn fatal debug ].each do |m|
        alias_method "#{m}_without_capture", m

        define_method m do |*args|
          @logdev.__send__ :puts, *(args.join("\n") + "\n")
          self.__send__ "#{m}_without_capture", *args
        end
      end
    end
  end
end

Logger.__send__ :include, CapturedLogger if ENV['CI']

$logger = Logger.new($stderr)
$logger.progname = 'elasticsearch'
$logger.formatter = proc do |severity, datetime, progname, msg|
  color = case severity
    when /INFO/ then :green
    when /ERROR|WARN|FATAL/ then :red
    when /DEBUG/ then :cyan
    else :white
  end
  "#{severity[0]} ".ansi(color, :faint) + msg.ansi(:white, :faint) + "\n"
end

$tracer = Logger.new($stdout)
$tracer.progname = 'elasticsearch.tracer'
$tracer.formatter = proc { |severity, datetime, progname, msg| "#{msg}\n" }

$url = ENV.fetch('TEST_CLUSTER_URL', "http://elastic:changeme@localhost:#{ENV['TEST_CLUSTER_PORT'] || 9260}")

$client = Elasticsearch::Client.new url: $url

$es_version = $client.info['version']['number']

$client.transport.logger = $logger unless ENV['QUIET'] || ENV['CI']
$original_client = $client.clone

require 'test_helper'

module Elasticsearch
  module YamlTestSuite
    $last_response = ''
    $results = {}
    $stash   = {}

    module Utils
      def titleize(word)
        word.to_s.gsub(/[^\w]+/, ' ').gsub(/\b('?[a-z])/) { $1.capitalize }.tr('_', ' ')
      end

      def symbolize_keys(object)
        if object.is_a? Hash
          object.reduce({}) { |memo,(k,v)| memo[k.to_sym] = symbolize_keys(v); memo }
        else
          object
        end
      end

      extend self
    end

    module Runner
      def perform_api_call(test, api, arguments=nil)
        namespace = api.split('.')

        replacer = lambda do |value|
          case value
            when Array
              value.map { |v| replacer.call(v) }
            when Hash
              Hash[ value.map { |v| replacer.call(v) } ]
            else
              fetch_or_return value
          end
        end

        timefixer = lambda do |value|
          if value.is_a?(Time)
            value.iso8601
          else
            value
          end
        end

        arguments = Hash[
          arguments.map do |key, value|
            replacement = replacer.call(value)
            replacement = timefixer.call(replacement)
            [key, replacement]
          end
        ]

        $stderr.puts "[#{api}] ARGUMENTS: #{arguments.inspect}" if ENV['DEBUG']

        $last_response = namespace.reduce($client) do |memo, current|
          unless current == namespace.last
            memo = memo.send(current)
          else
            arguments ? memo = memo.send(current, arguments) : memo = memo.send(current)
          end
          memo
        end

        $results[test.hash] = $last_response
      end

      def evaluate(test, property, response=nil)
        response ||= $results[test.hash]
        property.gsub(/\\\./, '_____').split('.').reduce(response) do |memo, attr|
          if memo
            if attr
              attr = attr.gsub(/_____/, '.')
              attr = $stash[attr] if attr.start_with? '$'
            end
            memo = memo.is_a?(Hash) ? memo[attr] : memo[attr.to_i]
          end
          memo
        end
      end

      def in_context(name, &block)
        klass = Class.new(YamlTestCase)
        Object::const_set "%sTest" % name.split(/\s/).reject { |d| d.match(/^\d+/) }.map { |d| d.capitalize }.join('').gsub(/[^\w]+/, ''), klass
        klass.context name, &block
      end

      def fetch_or_return(var)
        if var.is_a?(String) && var =~ /^\$(.+)/
          $stash[var]
        else
          var
        end
      end

      def set(var, val)
        $stash["$#{var}"] = val
      end

      def skip?(actions)
        skip = actions.select { |a| a['skip'] }.first

        # Skip version
        if skip && skip['skip']['version']
          $stderr.puts "SKIP: #{skip.inspect}" if ENV['DEBUG']
          return skip['skip']['reason'] ? skip['skip']['reason'] : true if skip['skip']['version'] == 'all'

          min, max = skip['skip']['version'].split('-').map(&:strip)

          min_normalized = sprintf "%03d-%03d-%03d",
                           *min.split('.')
                               .map(&:to_i)
                               .fill(0, min.split('.').length, 3-min.split('.').length)

          max_normalized = sprintf "%03d-%03d-%03d",
                           *max.split('.')
                               .map(&:to_i)
                               .map(&:to_i)
                               .fill(0, max.split('.').length, 3-max.split('.').length)

          es_normalized  = sprintf "%03d-%03d-%03d", *$es_version.split('.').map(&:to_i)

          if ( min.empty? || min_normalized <= es_normalized ) && ( max.empty? || max_normalized >= es_normalized )
            return skip['skip']['reason'] ? skip['skip']['reason'] : true
          end

        # Skip features
        elsif skip && skip['skip']['features']
          skip_features = skip['skip']['features'].respond_to?(:split) ? skip['skip']['features'].split(',') : skip['skip']['features']
          if ( skip_features & SKIP_FEATURES.split(',') ).size > 0
            return skip['skip']['features']
          end
        end

        return false
      end

      extend self
    end

    class YamlTestCase < Minitest::Test; end
  end
end

include Elasticsearch::YamlTestSuite

rest_api_test_source = '../../../../x-plugins/elasticsearch/x-pack/*/src/test/resources/rest-api-spec/test/'
PATH = Pathname(ENV.fetch('TEST_REST_API_SPEC', File.expand_path(rest_api_test_source, __FILE__)))
suites  = Dir.glob(PATH.join('*')).map { |d| Pathname(d) }
suites  = suites.select { |s| s.to_s =~ Regexp.new(ENV['FILTER']) } if ENV['FILTER']

$stderr.puts "TEST SUITES: " + suites.map { |d| d.basename }.join(', ') if ENV['DEBUG']

suites.each do |suite|
  name = Elasticsearch::YamlTestSuite::Utils.titleize(suite.basename)

  Elasticsearch::YamlTestSuite::Runner.in_context name do
    # --- Register context setup -------------------------------------------
    #
    setup do
      $client.indices.delete index: '_all', ignore: 404
      $results = {}
      $stash   = {}
    end

    # --- Register context teardown ----------------------------------------
    #
    teardown do
      $client.indices.delete index: '_all', ignore: 404
    end

    # --- Parse tests ------------------------------------------------------
    #
    files = Dir[suite.join('*.{yml,yaml}')]
    files.each do |file|
      tests = YAML.load_documents File.new(file)

      # Extract setup and teardown actions
      setup_actions    = tests.select { |t| t['setup'] }.first['setup'] rescue []
      teardown_actions = tests.select { |t| t['teardown'] }.first['teardown'] rescue []

      # Skip all the tests when `skip` is part of the `setup` part
      if features = Runner.skip?(setup_actions)
        $stdout.puts "#{'SKIP'.ansi(:yellow)} [#{name}] #{file.gsub(PATH.to_s, '').ansi(:bold)} (Feature not implemented: #{features})"
        next
      end

      # Remove setup/teardown actions from tests
      tests = tests.reject { |t| t['setup'] || t['teardown'] }

      # Add setup/teardown actions to each individual test
      tests.each { |t| t[t.keys.first] << { 'setup'    => setup_actions } }
      tests.each { |t| t[t.keys.first] << { 'teardown' => teardown_actions } }

      tests.each do |test|
        context '' do
          test_name = test.keys.first.to_s + (ENV['QUIET'] ? '' : " | #{file.gsub(PATH.to_s, '').ansi(:bold)}")
          actions   = test.values.first

          if reason = Runner.skip?(actions)
            $stdout.puts "#{'SKIP'.ansi(:yellow)} [#{name}] #{test_name} (Reason: #{reason})"
            next
          end

          # --- Register test setup -------------------------------------------
          setup do
            actions.select { |a| a['setup'] }.first['setup'].each do |action|
              if action['do']
                api, arguments = action['do'].to_a.first
                arguments      = Utils.symbolize_keys(arguments)
                Runner.perform_api_call((test.to_s + '___setup'), api, arguments)
              end
              if action['set']
                stash = action['set']
                property, variable = stash.to_a.first
                result  = Runner.evaluate(test, property, $last_response)
                $stderr.puts "STASH: '$#{variable}' => #{result.inspect}" if ENV['DEBUG']
                Runner.set variable, result
              end
            end
          end

          # --- Register test teardown -------------------------------------------
          teardown do
            actions.select { |a| a['teardown'] }.first['teardown'].each do |action|
              if action['do']
                api, arguments = action['do'].to_a.first
                arguments      = Utils.symbolize_keys(arguments)
                Runner.perform_api_call((test.to_s + '___teardown'), api, arguments)
              end
              if action['set']
                stash = action['set']
                property, variable = stash.to_a.first
                result  = Runner.evaluate(test, property, $last_response)
                $stderr.puts "STASH: '$#{variable}' => #{result.inspect}" if ENV['DEBUG']
                Runner.set variable, result
              end
            end unless teardown_actions.empty?
          end

          # --- Register test method ------------------------------------------
          should test_name do
            actions.each do |action|
              $stderr.puts "ACTION: #{action.inspect}" if ENV['DEBUG']

              if headers = action['do'] && action['do'].delete('headers')
                puts "HEADERS: " + headers.inspect if ENV['DEBUG']
                $client = Elasticsearch::Client.new url: $url, transport_options: { headers: headers }
                $client.transport.logger = $logger unless ENV['QUIET'] || ENV['CI']
              else
                $client = $original_client
              end

              case

                # --- Perform action ------------------------------------------
                #
                when action['do']
                  catch_exception = action['do'].delete('catch') if action['do']
                  api, arguments = action['do'].to_a.first
                  arguments      = Utils.symbolize_keys(arguments)

                  begin
                    $results[test.hash] = Runner.perform_api_call(test, api, arguments)
                  rescue Exception => e
                    begin
                      $results[test.hash] = MultiJson.load(e.message.match(/{.+}/, 1).to_s)
                    rescue MultiJson::ParseError
                      $stderr.puts "RESPONSE: Cannot parse JSON from error message: '#{e.message}'" if ENV['DEBUG']
                    end

                    if catch_exception
                      $stderr.puts "CATCH: '#{catch_exception}': #{e.inspect}" if ENV['DEBUG']
                      case e
                        when 'missing'
                          assert_match /\[404\]/, e.message
                        when 'conflict'
                          assert_match /\[409\]/, e.message
                        when 'request'
                          assert_match /\[500\]/, e.message
                        when 'param'
                          raise ArgumentError, "NOT IMPLEMENTED"
                        when /\/.+\//
                          assert_match Regexp.new(catch_exception.tr('/', '')), e.message
                      end
                    else
                      raise e
                    end
                  end

                # --- Evaluate predicates -------------------------------------
                #
                when property = action['is_true']
                  result = Runner.evaluate(test, property)
                  $stderr.puts "CHECK: Expected '#{property}' to be true, is: #{result.inspect}" if ENV['DEBUG']
                  assert(result, "Property '#{property}' should be true, is: #{result.inspect}")

                when property = action['is_false']
                  result = Runner.evaluate(test, property)
                  $stderr.puts "CHECK: Expected '#{property}' to be nil, false, 0 or empty string, is: #{result.inspect}" if ENV['DEBUG']
                  assert "Property '#{property}' should be nil, false, 0 or empty string, but is: #{result.inspect}" do
                    result.nil? || result == false || result == 0 || result == ''
                  end

                when a = action['match']
                  property, value = a.to_a.first

                  if value.is_a?(String) && value =~ %r{\s*^/\s*.*\s*/$\s*}mx # Begins and ends with /
                    pattern = Regexp.new(value.strip[1..-2], Regexp::EXTENDED|Regexp::MULTILINE)
                  else
                    value  = Runner.fetch_or_return(value)
                  end

                  if property == '$body'
                    result = $results[test.hash]
                  else
                    result = Runner.evaluate(test, property)
                  end

                  if pattern
                    $stderr.puts "CHECK: Expected '#{property}' to match #{pattern}, is: #{result.inspect}" if ENV['DEBUG']
                    assert_match(pattern, result)
                  else
                    value = value.reduce({}) { |memo, (k,v)| memo[k] =  Runner.fetch_or_return(v); memo  } if value.is_a? Hash
                    $stderr.puts "CHECK: Expected '#{property}' to be '#{value}', is: #{result.inspect}" if ENV['DEBUG']

                    assert_equal(value, result)
                  end

                when a = action['length']
                  property, value = a.to_a.first

                  result = Runner.evaluate(test, property)
                  length = result.size
                  $stderr.puts "CHECK: Expected '#{property}' to be #{value}, is: #{length.inspect}" if ENV['DEBUG']
                  assert_equal(value, length)

                when a = action['lt'] || action['gt'] || action['lte'] || action['gte']
                  property, value = a.to_a.first
                  operator = case
                    when action['lt']
                      '<'
                    when action['gt']
                      '>'
                    when action['lte']
                      '<='
                    when action['gte']
                      '>='
                  end

                  result  = Runner.evaluate(test, property)
                  message = "Expected '#{property}' to be #{operator} #{value}, is: #{result.inspect}"

                  $stderr.puts "CHECK: #{message}" if ENV['DEBUG']
                  assert_operator result, operator.to_sym, value.to_i

                when stash = action['set']
                  property, variable = stash.to_a.first
                  result  = Runner.evaluate(test, property)
                  $stderr.puts "STASH: '$#{variable}' => #{result.inspect}" if ENV['DEBUG']
                  Runner.set variable, result
              end
            end
          end
        end
      end
    end

  end

end
