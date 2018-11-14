module Panomosity
  class Panorama
    include Panomosity::Utils

    attr_accessor :images, :control_points, :variable, :optimisation_variables, :logger, :options

    def initialize(input, options = {})
      @input = input
      @options = options
      @options[:verbosity] ||= 0
      @images = Image.parse(@input)
      @variable = PanoramaVariable.parse(@input).first
      ControlPoint.parse(@input)
      @control_points = ControlPoint.calculate_distances(@images, @variable)
      @optimisation_variables = OptimisationVariable.parse(@input)
      @logger = Panomosity.logger
    end

    def clean_control_points
      Pair.calculate_neighborhoods(self)
      control_points_to_keep = Pair.good_control_points_to_keep
      bad_control_points = control_points.reject { |cp| control_points_to_keep.map(&:raw).include?(cp.raw) }
      # far_control_points = control_points.select { |cp| cp.prdist > 50 }
      control_points_to_clean = bad_control_points.uniq(&:raw)

      # log warnings
      control_point_ratio = control_points_to_clean.count.to_f / control_points.count
      logger.warn "Removing more than 30% (#{(control_point_ratio*100).round(4)}%) of control points. May potentially cause issues." if control_point_ratio >= 0.3
      control_point_pair_ratio = Pair.without_enough_control_points(ignore_connected: true).count.to_f / Pair.all.count
      logger.warn "More than 50% (#{(control_point_pair_ratio*100).round(4)}%) of pairs have fewer than 3 control points. May potentially cause issues." if control_point_pair_ratio >= 0.5

      control_points_to_clean
    end

    def fix_unconnected_image_pairs
      logger.info 'finding unconnected image pairs'

      Pair.calculate_neighborhoods(self)
      Pair.calculate_neighborhood_groups

      unconnected_image_pairs = Pair.unconnected
      logger.debug unconnected_image_pairs.map { |i| { type: i.type, pair: i.pair.map(&:id) } }

      logger.info 'finding control points with unrealistic distances (<1)'
      bad_control_points = control_points.select { |cp| cp.pdist <= 1.0 }
      logger.info 'adding pairs that have do not have enough control points (<3)'
      changing_control_points_pairs = Pair.without_enough_control_points
      changed_pairs = []

      logger.info 'writing new control points'
      control_point_lines_started = false
      @lines = @input.each_line.map do |line|
        cp = ControlPoint.parse_line(line)
        if cp.nil?
          # Control point lines ended
          if control_point_lines_started
            control_point_lines_started = false
            unconnected_image_pairs.map do |pair|
              generate_control_points(pair: pair, message: 'adding control points connecting')
            end + [line]
          else
            next line
          end
        else
          control_point_lines_started = true
          bad_control_point = bad_control_points.find { |c| c.raw == line }
          changing_control_point_pair = changing_control_points_pairs.find { |pair| pair.control_points.find { |c| c.raw == line } }

          if bad_control_point
            generate_control_points(bad_control_point: bad_control_point, message: 'replacing unrealistic control point connecting')
          elsif changing_control_point_pair && !changed_pairs.include?(changing_control_point_pair.to_s)
            changed_pairs << changing_control_point_pair.to_s
            bad_control_point = changing_control_point_pair.control_points.first
            generate_control_points(bad_control_point: bad_control_point, message: 'adding control points connecting')
          else
            next line
          end
        end
      end.compact.flatten
    end

    def generate_control_points(pair: nil, bad_control_point: nil, message: '')
      if pair
        if pair.horizontal?
          group = NeighborhoodGroup.horizontal.first
        else
          group = NeighborhoodGroup.vertical.first
        end
      else
        if bad_control_point.conn_type == :horizontal
          group = NeighborhoodGroup.horizontal.first
        else
          group = NeighborhoodGroup.vertical.first
        end
      end

      control_point = ControlPoint.new(group.center.center.attributes)

      if pair
        control_point[:n] = pair.first_image.id
        control_point[:N] = pair.last_image.id
      else
        control_point[:n] = bad_control_point[:n]
        control_point[:N] = bad_control_point[:N]
      end

      image_1 = images.find { |i| i.id == control_point[:n] }
      image_2 = images.find { |i| i.id == control_point[:N] }

      x_diff = group.x_avg + (image_2.d - image_1.d)
      y_diff = group.y_avg + (image_2.e - image_1.e)

      x1 = x_diff <= 0 ? -x_diff + 15 : 0
      y1 = y_diff <= 0 ? -y_diff + 15 : 0

      control_point[:x] = x1
      control_point[:X] = x1 + x_diff
      control_point[:y] = y1
      control_point[:Y] = y1 + y_diff

      logger.info "#{message} #{control_point.n1} <> #{control_point.n2}"
      i = images.first
      3.times.map do
        if control_point.conn_type == :horizontal
          control_point[:y] += i.h * 0.25
          control_point[:Y] += i.h * 0.25
        else
          control_point[:x] += i.w * 0.25
          control_point[:X] += i.w * 0.25
        end
        # marks the control point as generated

        control_point[:g] = 0
        control_point.to_s
      end.join
    end

    def get_neigborhood_info
      Pair.calculate_neighborhoods(self)
      Pair.calculate_neighborhood_groups
      Pair.info
      NeighborhoodGroup.info
    end

    def diagnose
      Pair.calculate_neighborhoods(self)
      Pair.calculate_neighborhood_groups

      recommendations = []

      logger.debug "total number of control points: #{control_points.count}"
      logger.debug "total number of generated control points: #{control_points.select(&:generated?).count}"
      logger.debug "total number of not generated control points: #{control_points.select(&:not_generated?).count}"

      control_point_pair_ratio = Pair.without_enough_control_points(ignore_connected: true).count.to_f / Pair.all.count
      logger.warn "More than 50% (#{(control_point_pair_ratio*100).round(4)}%) of pairs have fewer than 3 control points. May potentially cause issues." if control_point_pair_ratio >= 0.5

      control_point_generated_ratio = control_points.select(&:generated?).count.to_f / control_points.select(&:not_generated?).count
      if control_point_generated_ratio >= 0.3
        message = <<~MESSAGE
          More than 30% (#{(control_point_generated_ratio*100).round(4)}%) control points were generated.
          This indicates a failure to find control points between images pairs due to poor lighting or insufficient complexity.
        MESSAGE
        logger.warn message
      end

      # neighborhood group tests
      group_count = NeighborhoodGroup.horizontal.count
      if group_count < 5
        message = <<~MESSAGE
          Total number of horizontal neighborhood groups is #{group_count} which is very low.
          This can mean either low variation in control points distances or that not enough control points could be found.
        MESSAGE
        logger.warn message
      end

      group_std_avg = calculate_average(values: NeighborhoodGroup.horizontal[0..4].map(&:prdist_std))
      if group_std_avg > 1.0
        message = <<~MESSAGE
          The standard deviation of distances in the top 5 horizontal neighborhood groups is #{group_std_avg} which is high.
          The standard deviation implies that control points neighborhoods making up this group can vary more than 1.0 in distance.
          On highly optimized images (with many good control points) this standard deviation should be near 0.
          This could mean that even after optimization, there may be a seam on an individual pair.
          This also means that the images may represent a 3D object that has perspective differences.
        MESSAGE
        logger.warn message
      end

      group_control_points = NeighborhoodGroup.horizontal.first.control_points.count
      total_control_points = Pair.horizontal.map(&:control_points).flatten.uniq(&:raw).count
      group_control_point_ratio = group_control_points.to_f / total_control_points
      if group_control_point_ratio < 0.2
        message = <<~MESSAGE
          Less than 20% (#{(group_control_point_ratio*100).round(4)}%) of horizontal control points in the best
          horizontal neighborhood group (#{group_control_points}) make up the total number of horizontal control points (#{total_control_points}).
          This means panosmosity failed to find a neighborhood group that would include enough similarities between control point distances.
          There will very likely be seams horizontally.
        MESSAGE
        logger.warn message
        recommendations << 'horizontal'
      end

      group_count = NeighborhoodGroup.vertical.count
      if group_count < 5
        message = <<~MESSAGE
          Total number of vertical neighborhood groups is #{group_count} which is very low.
          This can mean either low variation in control points distances or that not enough control points could be found.
        MESSAGE
        logger.warn message
      end

      group_std_avg = calculate_average(values: NeighborhoodGroup.vertical[0..4].map(&:prdist_std))
      if group_std_avg > 1.0
        message = <<~MESSAGE
          The standard deviation of distances in the top 5 vertical neighborhood groups is #{group_std_avg} which is high.
          The standard deviation implies that control points neighborhoods making up this group can vary more than 1.0 in distance.
          On highly optimized images (with many good control points) this standard deviation should be near 0.
          This could mean that even after optimization, there may be a seam on an individual pair.
          This also means that the images may represent a 3D object that has perspective differences.
        MESSAGE
        logger.warn message
      end

      group_control_points = NeighborhoodGroup.vertical.first.control_points.count
      total_control_points = Pair.vertical.map(&:control_points).flatten.uniq(&:raw).count
      group_control_point_ratio = group_control_points.to_f / total_control_points
      if group_control_point_ratio < 0.2
        message = <<~MESSAGE
          Less than 20% (#{(group_control_point_ratio*100).round(4)}%) of vertical control points in the best
          vertical neighborhood group (#{group_control_points}) make up the total number of vertical control points (#{total_control_points}).
          This means panosmosity failed to find a neighborhood group that would include enough similarities between control point distances.
          There will very likely be seams vertically.
        MESSAGE
        logger.warn message
        recommendations << 'vertical'
      end

      if recommendations.empty?
        logger.warn 'No recommendations'
        puts 'none'
      else
        logger.warn 'Recommendations are to regenerate with control points generated from calibration cards:'
        puts recommendations.join(',')
      end
    end
  end
end
