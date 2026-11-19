# frozen_string_literal: true

require 'json'

# Reads a state machine definition (`let(:machine)` names the file in state_machines/) as a graph, for the
# structure specs: where each state goes, which states reach an ending, which JSONPaths a state reads.
module StateMachineGraph
  def states
    JSON.parse(File.read(File.join(__dir__, '..', '..', 'state_machines', "#{machine}.json"))).fetch('States')
  end

  def targets(state)
    [state['Next'], state['Default'], *Array(state['Choices']).map { |c| c['Next'] },
     *Array(state['Catch']).map { |c| c['Next'] }].compact
  end

  def deciding_choices(name)
    states.select { |_, s| targets(s).include?(name) }.flat_map do |source, state|
      next [source] if state['Type'] == 'Choice'

      state.key?('ResultPath') && state['ResultPath'].nil? ? deciding_choices(source) : []
    end
  end

  def reachable(from)
    seen = []
    queue = Array(from)
    until queue.empty?
      name = queue.shift
      next if seen.include?(name)

      seen << name
      queue.concat(targets(states.fetch(name)))
    end
    seen
  end

  # Every JSONPath a state reads: Parameters values ending .$, Choice variables, Input/Output paths.
  def paths(state)
    found = []
    walk = lambda do |obj|
      case obj
      when Hash
        obj.each do |key, value|
          path_key = key.end_with?('.$') || %w[Variable InputPath OutputPath].include?(key)
          found << value if path_key && value.is_a?(String)
          walk.call(value)
        end
      when Array then obj.each { |v| walk.call(v) }
      end
    end
    walk.call(state.except('Comment'))
    found
  end
end
