# -*- encoding: utf-8; frozen_string_literal: true -*-
#
#--
# This file is part of HexaPDF.
#
# HexaPDF - A Versatile PDF Creation and Manipulation Library For Ruby
# Copyright (C) 2014-2026 Thomas Leitner
#
# HexaPDF is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License version 3 as
# published by the Free Software Foundation with the addition of the
# following permission added to Section 15 as permitted in Section 7(a):
# FOR ANY PART OF THE COVERED WORK IN WHICH THE COPYRIGHT IS OWNED BY
# THOMAS LEITNER, THOMAS LEITNER DISCLAIMS THE WARRANTY OF NON
# INFRINGEMENT OF THIRD PARTY RIGHTS.
#
# HexaPDF is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public
# License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with HexaPDF. If not, see <http://www.gnu.org/licenses/>.
#
# The interactive user interfaces in modified source and object code
# versions of HexaPDF must display Appropriate Legal Notices, as required
# under Section 5 of the GNU Affero General Public License version 3.
#
# In accordance with Section 7(b) of the GNU Affero General Public
# License, a covered work must retain the producer line in every PDF that
# is created or manipulated using HexaPDF.
#
# If the GNU Affero General Public License doesn't fit your need,
# commercial licenses are available at <https://gettalong.at/hexapdf/>.
#++

module HexaPDF
  module Utils

    # This module provides some mathematical helper functions.
    module MathHelpers

      module_function

      # Converts degrees to radians.
      def deg_to_rad(degrees)
        degrees * Math::PI / 180
      end

      # Converts radians to degress.
      def rad_to_deg(radians)
        radians * 180 / Math::PI
      end

      # Solves the system of linear equations +matrix+ * x = +vector+ where +matrix+ is an
      # Array of three rows, each row containing three numbers, and +vector+ is an Array of
      # three numbers.
      #
      # Returns the solution as an Array of three numbers, or +nil+ if the matrix is singular
      # (within the given +eps+ threshold, relative to the magnitude of the pivot values).
      def solve_linear_system3(matrix, vector, eps = 1e-12)
        a = matrix.map(&:dup)
        b = vector.dup
        scale = a.flatten.map(&:abs).max.to_f
        return nil if scale.zero?

        3.times do |col|
          pivot = (col...3).max_by {|row| a[row][col].abs }
          if a[pivot][col].abs <= eps * scale
            return nil
          end
          if pivot != col
            a[col], a[pivot] = a[pivot], a[col]
            b[col], b[pivot] = b[pivot], b[col]
          end

          ((col + 1)...3).each do |row|
            factor = a[row][col].to_f / a[col][col]
            (col...3).each {|j| a[row][j] -= factor * a[col][j] }
            b[row] -= factor * b[col]
          end
        end

        result = Array.new(3, 0.0)
        2.downto(0) do |row|
          sum = b[row].to_f
          ((row + 1)...3).each {|j| sum -= a[row][j] * result[j] }
          result[row] = sum / a[row][row]
        end
        result
      end

    end

  end
end
