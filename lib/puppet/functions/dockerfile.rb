require 'puppet/functions'
require 'puppet/node'
require 'puppet/parser/compiler'
require 'puppet/parser/scope'
require 'puppet/pops/evaluator/evaluator_impl'
require 'puppet/pops/evaluator/puppet_proc'
require 'puppet/pops/evaluator/closure'

Puppet::Functions.create_function('dockerfile') do
  dispatch :build do
    block_param 'Callable[0,0]', :block
  end

  def build(&block)
    node = Puppet::Node.new('container')
    compiler = Puppet::Parser::Compiler.new(node)
    scope = Puppet::Parser::Scope.new(compiler)

    # Include the function's outer (closure) scope
    # as the evaluating scope's parent. This allows
    # access to variables defined in the scope the
    # function was called in.
    scope.parent = closure_scope

    # Certain functions of the evaluator require that
    # the source AST be present on the scope.
    scope.source = closure_scope.source

    # Evaluate the function's block in the newly
    # instantiated scope.
    rewrap_puppet_proc_closure(scope, &block).call

    dockerfile = visit_resources(scope.compiler.catalog.resources)
    dockerfile.content
  end

  # TODO: Walk dependency graph instead of visiting in evaluation order.
  def visit_resources(resources)
    visitor = Visitor.new

    resources.reject! {|resource| resource.type == 'Stage' || resource.type == 'Class' }
    resources.map(&visitor.method(:visit))

    Dockerfile.from_context(visitor.context)
  end

  # rewrap_puppet_proc_closure takes a PuppetProc as
  # provided by a Callable function parameter, removes
  # it from the default closure built by the evaluator,
  # and wraps it in a new closure which is bound to
  # the provided scope.
  #
  # This is used to evaluate the contents of a Puppet
  # lambda outside of the calling scope.
  #
  # Returns a PuppetProc with the closure.
  def rewrap_puppet_proc_closure(scope, &block)
    lambda = block.closure.model
    evaluator = Puppet::Pops::Evaluator::EvaluatorImpl.new
    closure = Puppet::Pops::Evaluator::Closure.new(evaluator, lambda, scope)

    Puppet::Pops::Evaluator::PuppetProc.new(closure) {|*args| closure.call(*args) }
  end

  # Dockerfile models a Dockerfile visitor intended to
  # evaluate a Visitor::Context, and ultimately compile
  # a usable Dockerfile in a string.
  class Dockerfile
    attr_reader :content

    def self.from_context(context)
      instance = new
      context.accept(instance)
      instance
    end

    def initialize
      @content = ""
    end

    def append_directive(key, value)
      @content.concat("#{key.to_s.upcase} #{value}\n")
    end

    def append_line(line)
      @content.concat("#{line}\n")
    end
  end

  # Visitor is responsible for two things primarily:
  # containing the visitor context object, and providing logic
  # to evaluate various resources while handling the interface
  # of their associated provider(s).
  class Visitor
    # Context contains the Visitor's state, and will ultimately
    # be visited by an instance of Dockerfile.
    class Context
      attr_accessor :osfamily, :visited
      attr_reader :scripts

      def initialize
        @visited = 0
        @scripts = []
      end

      def increment!
        @visited += 1
      end

      def push_command(script)
        scripts << script
      end

      def accept(visitor)
        scripts.each { |script| visitor.append_line(script) }
      end
    end

    attr_reader :context

    def initialize
      @context = Context.new
    end

    def visit(resource)
      resource = resource.to_ral

      context.osfamily = resource[:osfamily] if resource.type == :parent_image

      raise Puppet::Error, "parent_image resource declaration was not first in dockerfile lambda. You must set the OS family of the parent container image before resources can be evaluated for the Dockerfile." unless context.osfamily

      provider = assign_provider(resource)

      raise Puppet::Error, "Resource type '#{resource.type}' can't be included in the Dockerfile because the '#{provider}' provider doesn't implement a dockerfile_line method." unless resource.provider.respond_to?(:dockerfile_line)

      script = resource.provider.dockerfile_line(context)

      raise Puppet::Error, "Resource type '#{resource.type}' can't be included in the Dockerfile because the '#{provider}' provider's dockerfile_line method didn't return a string." unless script.is_a? String

      context.push_command(script)
      context.increment!
    end

    def assign_provider(resource, provider="docker_#{context.osfamily}", fallback=true)
      begin
        resource.provider = provider
      rescue
        fallback ? assign_provider(resource, "docker", false)
        : raise("Resource type '#{resource.type}' can't be included in the Dockerfile because it lacks a Dockerfile provider.")
      end
    end
  end
end
