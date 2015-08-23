module RegexpExamples
  # All Group#result methods return an array of GroupResult objects
  # The key objective here is to keep track of all capture groups, in order
  # to fill in backreferences
  class GroupResult < String
    attr_reader :group_id, :subgroups
    def initialize(result, group_id = nil, subgroups = [])
      @group_id = group_id
      @subgroups = result.respond_to?(:group_id) ? result.all_subgroups : subgroups
      super(result)
    end

    def all_subgroups
      [self, subgroups].flatten.keep_if(&:group_id)
    end

    def swapcase
      # Override to preserve subgroups
      GroupResult.new(super.to_s, group_id, subgroups)
    end
  end

  # A helper method for mixing in to Group classes...
  # Needed because sometimes (for performace) group results are lazy enumerators;
  # Meanwhile other times (again, for performance!) group results are just arrays
  module ForceLazyEnumerators
    def force_if_lazy(arr_or_enum)
      arr_or_enum.respond_to?(:force) ? arr_or_enum.force : arr_or_enum
    end
  end

  # A helper method for mixing in to Group classes...
  # Needed for generating a complete results set when the ignorecase
  # regexp option has been set
  module GroupWithIgnoreCase
    include ForceLazyEnumerators
    attr_reader :ignorecase
    def result
      group_result = super
      if ignorecase
        group_result_array = force_if_lazy(group_result)
        group_result_array
          .concat(group_result_array.map(&:swapcase))
          .uniq
      else
        group_result
      end
    end
  end

  # A helper method for mixing in to Group classes...
  # Uses Array#sample to randomly choose one result from all
  # possible examples
  module RandomResultBySample
    include ForceLazyEnumerators
    def random_result
      force_if_lazy(result).sample(1)
    end
  end

  # The most "basic" possible group.
  # For example, /x/ contains one SingleCharGroup
  class SingleCharGroup
    include RandomResultBySample
    prepend GroupWithIgnoreCase
    def initialize(char, ignorecase)
      @char = char
      @ignorecase = ignorecase
    end

    def result
      [GroupResult.new(@char)]
    end
  end

  # Used as a workaround for when a group is expected to be returned,
  # but there are no results for the group.
  # i.e. PlaceHolderGroup.new.result == '' == SingleCharGroup.new('').result
  # (But using PlaceHolderGroup makes it clearer what the intention is!)
  class PlaceHolderGroup
    include RandomResultBySample
    def result
      [GroupResult.new('')]
    end
  end

  # The most generic type of group, which contains 0 or more characters.
  # Technically, this is the ONLY type of group that is truly necessary
  # However, having others both improves performance through various optimisations,
  # and clarifies the code's intention.
  # The most common example of CharGroups is: /[abc]/
  class CharGroup
    include RandomResultBySample
    prepend GroupWithIgnoreCase
    def initialize(chars, ignorecase)
      @chars = chars
      @ignorecase = ignorecase
    end

    def result
      @chars.lazy.map do |result|
        GroupResult.new(result)
      end
    end
  end

  # A special case of CharGroup, for the pattern /./
  # (For example, we never need to care about ignorecase here!)
  class DotGroup
    include RandomResultBySample
    attr_reader :multiline
    def initialize(multiline)
      @multiline = multiline
    end

    def result
      chars = multiline ? CharSets::Any : CharSets::AnyNoNewLine
      chars.lazy.map do |result|
        GroupResult.new(result)
      end
    end
  end

  # A collection of other groups. Basically any regex that contains
  # brackets will be parsed using one of these. The simplest example is:
  # /(a)/ - Which is a MultiGroup, containing one SingleCharGroup
  class MultiGroup
    attr_reader :group_id
    def initialize(groups, group_id)
      @groups = groups
      @group_id = group_id
    end

    # Generates the result of each contained group
    # and adds the filled group of each result to itself
    def result
      strings = @groups.map { |repeater| repeater.public_send(__method__) }
      RegexpExamples.permutations_of_strings(strings).map do |result|
        GroupResult.new(result, group_id)
      end
    end

    alias_method :random_result, :result
  end

  # A boolean "or" group.
  # The implementation is to pass in 2 set of (repeaters of) groups.
  # The simplest example is: /a|b/
  # If you have more than one boolean "or" operator, then this is initially
  # parsed as an OrGroup containing another OrGroup. However, in order to avoid
  # probability distribution issues in Regexp#random_example, this then gets
  # simplified down to one OrGroup containing 3+ repeaters.
  class OrGroup
    attr_reader :repeaters_list

    def initialize(left_repeaters, right_repeaters)
      @repeaters_list = [left_repeaters, *merge_if_orgroup(right_repeaters)]
    end

    def result
      result_by_method(:map_results)
    end

    def random_result
      result_by_method(:map_random_result).sample(1)
    end

    private

    def result_by_method(method)
      repeaters_list.map do |repeaters|
        RegexpExamples.public_send(method, repeaters)
      end
        .inject(:concat)
        .map do |result|
          GroupResult.new(result)
        end
        .uniq
    end

    def merge_if_orgroup(repeaters)
      if repeaters.size == 1 && repeaters.first.is_a?(OrGroup)
        repeaters.first.repeaters_list
      else
        [repeaters]
      end
    end
  end

  # This is a bit magic...
  # We substitute backreferences with PLACEHOLDERS. These are then, later,
  # replaced by the appropriate value. (See BackReferenceReplacer)
  # The simplest example is /(a) \1/ - So, we temporarily treat the "result"
  # of /\1/ as being "__1__". It later gets updated.
  class BackReferenceGroup
    include RandomResultBySample
    attr_reader :id
    def initialize(id)
      @id = id
    end

    def result
      [GroupResult.new("__#{@id}__")]
    end
  end
end
