require 'fiber'
module FixedWidth
  class Parser

    def initialize(definition, io)
      @definition = definition
      @io         = io
    end

    def parse(opts = {})
      reset_io!
      opts = @definition.options.merge(opts)
      case opts[:parse]
      when :by_bytes then parse_by_bytes(opts)
      when :any_order then parse_any_order(opts)
      when :in_order then parse_in_order(opts)
      else raise FixedWidth::ParseError.new %{
        Unknown parse method `#{opts[:parse].inspect}`
      }.squish
      end
    end

    private

    def parse_any_order(opts = {})
      opts = {
        verify_lines: true,
        save_unparsable: false,
        verify_sections: true
      }.merge(opts)
      output = {}
      line_number = 0
      failed = []
      while(line = next_line!) do
        section = @definition.sections.detect{ |s|
          s.match(line) && (!s.singular || !output[s.name])
        }
        if section
          add_to_section(output, section, line)
        elsif opts[:verify_lines]
          failed << [line_number, line]
        elsif opts[:save_unparsable]
          (output[:__unparsable] ||= []) << [line_number, line]
        end
        line_number += 1
      end
      if opts[:verify_lines] && !failed.empty?
        lines = failed.map { |ind, line| "\n#{ind+1}: #{line}" }
        raise FixedWidth::UnusedLineError.new(
          "Could not match the following lines:#{lines}")
      end
      if opts[:verify_sections]
        missing = @definition.sections.select? { |sec|
          !output[sec.name] && !sec.optional
        }.map(&:name)
        unless missing.empty?
          raise FixedWidth::RequiredSectionNotFoundError.new(
            "The following required sections were not found: " +
              "#{missing.inspect}")
        end
      end
      output
    end

    def parse_in_order(opts = {})
      opts = { verify_lines: false }.merge(opts)
      output = {}
      sections = make_fiber(@definition.sections.each)
      left = loop do
        section = sections.resume unless section
        break line unless section
        line = next_line! unless line
        if section.match(line)
          add_to_section(output, section, line) { |singular|
            section = nil if singular
          }
          line = nil
        elsif !section.optional && output[section.name].blank?
          raise FixedWidth::RequiredSectionNotFoundError.new %{
            Required section '#{section.name}' was not found.
          }.squish
        else
          section = nil
        end
      end
      raise FixedWidth::UnusedLineError.new %{
        Not all lines were parsed! Stopped at: #{left}
      }.squish if opts[:verify_lines] && (left ||= next_line!)
      output
    end

    def parse_by_bytes(opts = {})
      output = {}
      raise FixedWidth::SectionsNotSameLengthError.new %{
        All sections must be the same length if parsing by bytes!
      }.squish unless all_same_length?

    end

    def parse_by_chars(opts = {})
      output = {}
      raise FixedWidth::SectionsNotSameLengthError.new %{
        All sections must be the same length if parsing by chararacters!
      }.squish unless all_same_length?
    end

    def add_to_section(arr, section, line)
      parsed = section.parse(line)
      if sing = !!section.singular
        arr[section.name] = parsed
      else
        (arr[section.name] ||= []) << parsed
      end
      yield sing if block_given?
    end

    def line_fiber
      @line_fiber ||= make_fiber(@io.each_line)
    end

    def reset_io!
      @io.rewind
      @line_fiber = nil
    end

    def next_line!
      line_fiber.alive? ? line_fiber.resume.try(:chomp) : nil
    end

    def all_same_length?
      first_length = @definition.sections.first.length
      @definition.sections.all? { |section|
        section.length == first_length
      }
    end

    def make_fiber(enumerator, terminate = nil)
      Fiber.new do
        enumerator.each do |ele|
          Fiber.yield(ele)
        end
        terminate
      end
    end

  end
end
