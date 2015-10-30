class Formatron
  class Configuration
    # Generates the CloudFormation templates
    module CloudFormation
      # exports params to CloudFormation ERB template
      class Template
        attr_reader :region, :target, :name, :bucket, :configuration

        def initialize(region:, target:, name:, bucket:, configuration:)
          @region = region
          @target = target
          @name = name
          @bucket = bucket
          @configuration = configuration
        end
      end

      def self.template(aws, formatronfile)
        template = _template_path
        erb = ERB.new File.read(template)
        erb.filename = template
        erb_template = erb.def_class Template, 'render()'
        _render aws, formatronfile, erb_template
      end

      def self._template_path
        File.join(
          File.dirname(File.expand_path(__FILE__)),
          File.basename(__FILE__, '.rb'),
          'bootstrap.json.erb'
        )
      end

      def self._render(aws, formatronfile, erb_template)
        erb_template.new(
          region: aws.region,
          target: formatronfile.target,
          name: formatronfile.name,
          bucket: formatronfile.bucket,
          configuration: formatronfile.bootstrap
        ).render
      end

      private_class_method(
        :_template_path,
        :_render
      )
    end
  end
end
