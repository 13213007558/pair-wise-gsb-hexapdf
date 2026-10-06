# -*- encoding: utf-8; frozen_string_literal: true -*-

module HexaPDF
  module Type
    class Shading

      # Adaptive sampling of shading patches into position/color grids.
      #
      # All patches of a shading are sampled with the same number of subdivisions per patch
      # edge. Since patches sharing an edge (via edge flags) use identical control points for
      # that edge, the shared edge is sampled at identical parameter positions in both patches
      # and no cracks appear between adjacent patches.
      module Sampler

        # A sampled vertex: #position is an [x, y] pair in shading space, #color an array of
        # color components with the shading's color function (if any) already applied.
        Vertex = Struct.new(:position, :color)

        # A parameter space region of a patch where the requested tolerance could not be met
        # within the allowed number of subdivisions.
        Region = Struct.new(:patch_index, :u_range, :v_range)

        # The sampling result for a single patch.
        class SampledPatch

          # The sampled Shading::Patch.
          attr_reader :patch

          # The number of subdivisions per patch edge; the grid has
          # (subdivisions + 1)**2 vertices.
          attr_reader :subdivisions

          # The sampled vertices (Shading::Sampler::Vertex objects), row by row: the vertex
          # with parameter position (i/subdivisions, j/subdivisions) has index
          # j * (subdivisions + 1) + i.
          attr_reader :vertices

          def initialize(patch, subdivisions, vertices) # :nodoc:
            @patch = patch
            @subdivisions = subdivisions
            @vertices = vertices
          end

          # Returns the vertex at grid position (+i+, +j+), corresponding to the parameter
          # position (i/subdivisions, j/subdivisions).
          def vertex_at(i, j)
            @vertices[j * (@subdivisions + 1) + i]
          end

          # Returns the grid cells as an array of quads; each quad is an array of four vertex
          # indices into #vertices, in counter-clockwise order starting at the bottom-left
          # corner (smallest u and v).
          def quads
            n = @subdivisions
            result = []
            n.times do |j|
              n.times do |i|
                bottom_left = j * (n + 1) + i
                result << [bottom_left, bottom_left + 1, bottom_left + n + 2,
                           bottom_left + n + 1]
              end
            end
            result
          end

        end

        # The result of sampling a whole shading.
        class Mesh

          # The sampled patches, an array of Shading::Sampler::SampledPatch.
          attr_reader :patches

          # The number of subdivisions per patch edge used for all patches.
          attr_reader :subdivisions

          # The tolerance used for sampling.
          attr_reader :tolerance

          # The parameter space regions (Shading::Sampler::Region objects) where the requested
          # tolerance could not be met within the allowed number of subdivisions.
          attr_reader :unmet_regions

          def initialize(patches:, subdivisions:, tolerance:, unmet_regions:) # :nodoc:
            @patches = patches
            @subdivisions = subdivisions
            @tolerance = tolerance
            @unmet_regions = unmet_regions
          end

          # Returns whether the requested tolerance was met everywhere, i.e. whether
          # #unmet_regions is empty.
          def tolerance_met?
            @unmet_regions.empty?
          end

        end

        # Cell-local test positions: the four edge midpoints and the center.
        TEST_POINTS = [[0.5, 0.0], [1.0, 0.5], [0.5, 1.0], [0.0, 0.5], [0.5, 0.5]].freeze

        module_function

        # Samples +patches+ (an array of Shading::Patch) with the given +color_transform+ (see
        # Shading#color_transform) and returns a Mesh.
        #
        # The number of subdivisions is doubled (starting at 1) until every grid cell satisfies
        # +tolerance+ or +max_subdivisions+ is reached. In the latter case the returned mesh
        # reports the parameter space regions that did not satisfy the tolerance via
        # Mesh#unmet_regions instead of silently claiming the requested accuracy.
        def sample(patches, color_transform, tolerance:, max_subdivisions:)
          raise ArgumentError, "tolerance must be positive" unless tolerance.positive?
          raise ArgumentError, "max_subdivisions must be >= 1" unless max_subdivisions >= 1

          n = 1
          loop do
            sampled = patches.map do |patch|
              SampledPatch.new(patch, n, evaluate_grid(patch, n, color_transform))
            end
            unmet = []
            sampled.each_with_index do |sampled_patch, patch_index|
              each_unflat_cell(sampled_patch, tolerance, color_transform) do |i, j|
                unmet << Region.new(patch_index,
                                    [i.to_f / n, (i + 1).to_f / n],
                                    [j.to_f / n, (j + 1).to_f / n])
              end
            end
            if unmet.empty? || n >= max_subdivisions
              return Mesh.new(patches: sampled, subdivisions: n, tolerance: tolerance,
                              unmet_regions: unmet)
            end
            n = [n * 2, max_subdivisions].min
          end
        end

        # Evaluates the (n + 1)**2 grid vertices of +patch+.
        def evaluate_grid(patch, n, color_transform)
          vertices = []
          (n + 1).times do |j|
            v = j.to_f / n
            (n + 1).times do |i|
              u = i.to_f / n
              vertices << Vertex.new(patch.evaluate(u, v),
                                     color_transform.call(patch.color_at(u, v)))
            end
          end
          vertices
        end

        # Yields the grid coordinates (i, j) of all cells that don't satisfy the tolerance.
        def each_unflat_cell(sampled_patch, tolerance, color_transform)
          n = sampled_patch.subdivisions
          n.times do |j|
            n.times do |i|
              yield(i, j) unless cell_flat?(sampled_patch, i, j, tolerance, color_transform)
            end
          end
        end

        # Returns whether the grid cell (+i+, +j+) satisfies the tolerance, i.e. whether the
        # exact surface position and color at the cell's edge midpoints and center deviate
        # from the bilinear interpolation of the cell corners by at most +tolerance+.
        def cell_flat?(sampled_patch, i, j, tolerance, color_transform)
          patch = sampled_patch.patch
          n = sampled_patch.subdivisions
          c00 = sampled_patch.vertex_at(i, j)
          c10 = sampled_patch.vertex_at(i + 1, j)
          c11 = sampled_patch.vertex_at(i + 1, j + 1)
          c01 = sampled_patch.vertex_at(i, j + 1)
          tolerance_squared = tolerance * tolerance

          TEST_POINTS.each do |du, dv|
            u = (i + du) / n
            v = (j + dv) / n
            position = patch.evaluate(u, v)
            dx = position[0] - bilinear(c00.position[0], c10.position[0], c11.position[0],
                                        c01.position[0], du, dv)
            dy = position[1] - bilinear(c00.position[1], c10.position[1], c11.position[1],
                                        c01.position[1], du, dv)
            return false if dx * dx + dy * dy > tolerance_squared

            color = color_transform.call(patch.color_at(u, v))
            color.each_index do |ci|
              approx = bilinear(c00.color[ci], c10.color[ci], c11.color[ci], c01.color[ci],
                                du, dv)
              return false if (color[ci] - approx).abs > tolerance
            end
          end
          true
        end

        # Bilinear interpolation of the corner values at the cell-local position (u, v).
        def bilinear(c00, c10, c11, c01, u, v)
          (1 - u) * (1 - v) * c00 + u * (1 - v) * c10 + u * v * c11 + (1 - u) * v * c01
        end

      end

    end
  end
end
