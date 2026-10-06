# -*- encoding: utf-8; frozen_string_literal: true -*-

module HexaPDF
  module Type
    class Shading

      # Evaluates the optional Function entry of a shading dictionary.
      #
      # PDF function types 0 (sampled, with linear interpolation), 2 (exponential
      # interpolation) and 3 (stitching) are supported, as well as an array of such functions
      # (one per output component). Type 4 (PostScript calculator) functions are not supported.
      #
      # See: PDF2.0 s7.10
      module Function

        # Creates a callable for the given PDF function object (a dictionary, a stream or an
        # array of function dictionaries).
        #
        # The returned object responds to +call(inputs)+ with an array of input values and
        # returns an array of output values. Inputs are clipped to the function's domain and
        # outputs to its range (if defined), as required by the PDF specification.
        def self.create(object)
          if object.kind_of?(HexaPDF::PDFArray) || object.kind_of?(Array)
            functions = object.map {|item| create(item) }
            return lambda {|inputs| functions.flat_map {|func| func.call(inputs) } }
          end
          case object[:FunctionType]
          when 0 then Sampled.new(object)
          when 2 then Exponential.new(object)
          when 3 then Stitching.new(object)
          when 4
            raise HexaPDF::Error, "Type 4 (PostScript calculator) functions are not supported"
          else
            raise HexaPDF::Error, "Unsupported function type #{object[:FunctionType].inspect}"
          end
        end

        # Clips +value+ to the range [+min+, +max+].
        def self.clip(value, min, max)
          value.clamp(min, max)
        end

        # Type 2 exponential interpolation function.
        class Exponential

          def initialize(dict)
            @domain = dict[:Domain]&.to_a || [0.0, 1.0]
            @c0 = dict[:C0]&.to_a || [0.0]
            @c1 = dict[:C1]&.to_a || [1.0]
            @exponent = dict[:N]
            @range = dict[:Range]&.to_a
          end

          def call(inputs)
            x = Function.clip(inputs[0], @domain[0], @domain[1])**@exponent
            @c0.each_with_index.map do |c0, index|
              value = c0 + x * (@c1[index] - c0)
              @range ? Function.clip(value, @range[2 * index], @range[2 * index + 1]) : value
            end
          end

        end

        # Type 3 stitching function.
        class Stitching

          def initialize(dict)
            @domain = dict[:Domain]&.to_a || [0.0, 1.0]
            @functions = dict[:Functions].map {|sub| Function.create(sub) }
            @bounds = dict[:Bounds].to_a
            @encode = dict[:Encode]&.to_a || [0.0, 1.0] * @functions.length
          end

          def call(inputs)
            x = Function.clip(inputs[0], @domain[0], @domain[1])
            index = 0
            index += 1 while index < @functions.length - 1 && x > @bounds[index]
            lower = index.zero? ? @domain[0] : @bounds[index - 1]
            upper = index == @functions.length - 1 ? @domain[1] : @bounds[index]
            e0 = @encode[2 * index]
            e1 = @encode[2 * index + 1]
            mapped = upper == lower ? e0 : e0 + (x - lower) * (e1 - e0) / (upper - lower)
            @functions[index].call([mapped])
          end

        end

        # Type 0 sampled function with multilinear interpolation (Order 1).
        class Sampled

          def initialize(dict)
            @domain = dict[:Domain].to_a
            @range = dict[:Range].to_a
            @size = dict[:Size].to_a
            @encode = dict[:Encode]&.to_a || @size.flat_map {|dim| [0, dim - 1] }
            @decode = dict[:Decode]&.to_a || @range
            order = dict[:Order] || 1
            if order != 1
              raise HexaPDF::Error, "Sampled functions with Order #{order} (cubic spline " +                "interpolation) are not supported"
            end
            bits_per_sample = dict[:BitsPerSample]
            @sample_max = (1 << bits_per_sample) - 1
            @output_count = @range.length / 2
            sample_count = @size.reduce(1, :*) * @output_count
            reader = BitReader.new(dict.stream)
            @samples = Array.new(sample_count) do |i|
              value = reader.read(bits_per_sample)
              unless value
                raise HexaPDF::Error, "Sampled function data is truncated at sample #{i}"
              end
              value
            end
          end

          def call(inputs)
            lows = []
            fracs = []
            @size.each_with_index do |dim_size, dim|
              d0 = @domain[2 * dim]
              d1 = @domain[2 * dim + 1]
              x = Function.clip(inputs[dim], d0, d1)
              e0 = @encode[2 * dim]
              e1 = @encode[2 * dim + 1]
              encoded = d1 == d0 ? e0 : e0 + (x - d0) * (e1 - e0) / (d1 - d0)
              encoded = Function.clip(encoded, 0, dim_size - 1)
              if dim_size == 1
                lows << 0
                fracs << 0.0
              elsif encoded >= dim_size - 1
                lows << dim_size - 2
                fracs << 1.0
              else
                lows << encoded.floor
                fracs << encoded - encoded.floor
              end
            end

            result = Array.new(@output_count, 0.0)
            (1 << @size.length).times do |corner|
              weight = 1.0
              sample_index = 0
              stride = 1
              @size.each_with_index do |dim_size, dim|
                bit = (corner >> dim) & 1
                weight *= bit == 1 ? fracs[dim] : 1.0 - fracs[dim]
                sample_index += (lows[dim] + bit) * stride
                stride *= dim_size
              end
              next if weight.zero?
              @output_count.times do |i|
                result[i] += weight * @samples[sample_index * @output_count + i]
              end
            end

            result.each_with_index.map do |sample, i|
              d0 = @decode[2 * i]
              d1 = @decode[2 * i + 1]
              value = d0 + sample / @sample_max.to_f * (d1 - d0)
              Function.clip(value, @range[2 * i], @range[2 * i + 1])
            end
          end

        end

      end

    end
  end
end
