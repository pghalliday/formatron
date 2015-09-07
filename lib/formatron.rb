require_relative 'formatron/config'
require_relative 'formatron/util/tar'
require_relative 'formatron/util/berks'
require_relative 'formatron/util/knife'
require 'aws-sdk'
require 'json'
require 'pathname'
require 'erb'
require 'tempfile'

VENDOR_DIR = 'vendor'
CREDENTIALS_FILE = 'credentials.json'
CLOUDFORMATION_DIR = 'cloudformation'
OPSWORKS_DIR = 'opsworks'
OPSCODE_DIR = 'opscode'
MAIN_CLOUDFORMATION_JSON = 'main.json'

class Formatron
  class TemplateParams
    def initialize(config)
      @config = config
    end
  end

  def initialize(dir, target)
    @dir = dir
    @target = target
    credentials_file = File.join(@dir, CREDENTIALS_FILE)
    credentials = JSON.parse(File.read(credentials_file))
    region = credentials['region']
    aws_credentials = Aws::Credentials.new(
      credentials['accessKeyId'],
      credentials['secretAccessKey']
    )
    @s3 = Aws::S3::Client.new(
      region: region,
      signature_version: 'v4',
      credentials: aws_credentials
    )
    @cloudformation = Aws::CloudFormation::Client.new(
      region: region,
      credentials: aws_credentials
    )
    @config = Formatron::Config.new(
      @dir,
      @target,
      credentials['region'],
      @s3,
      @cloudformation
    )
  end

  def deploy
    response = @s3.put_object(
      bucket: @config.s3_bucket,
      key: @config.config['formatronConfigS3Key'],
      body: JSON.pretty_generate(@config.config),
      server_side_encryption: 'aws:kms',
      ssekms_key_id: @config.config['formatronKmsKey']
    )
    opscode_dir = File.join(@dir, OPSCODE_DIR)
    if File.directory?(opscode_dir)
      need_to_deploy_first = false
      name = @config.name
      server_stack = @config.opscode.server_stack || name
      if server_stack.eql?(name)
        # first check if the stack is already deployed and ready
        begin
          response = @cloudformation.describe_stacks(
            stack_name: "#{@config.prefix}-#{@config.name}-#{@target}"
          )
          status = response.stacks[0].stack_status
          # rubocop:disable Metrics/LineLength
          fail "Chef server cloudformation stack is in an invalid state: #{status}" unless %w(
            ROLLBACK_COMPLETE
            CREATE_COMPLETE
            UPDATE_COMPLETE
            UPDATE_ROLLBACK_COMPLETE
          ).include?(status)
          # rubocop:enable Metrics/LineLength
        rescue Aws::CloudFormation::Errors::ValidationError => error
          # rubocop:disable Metrics/LineLength
          raise unless error.message.eql?("Stack with id #{@config.prefix}-#{@config.name}-#{@target} does not exist")
          # rubocop:enable Metrics/LineLength
          need_to_deploy_first = true
        end
      end
      if need_to_deploy_first
        vendor_dir = File.join(@dir, VENDOR_DIR)
        FileUtils.rm_rf vendor_dir
        Dir.glob(File.join(opscode_dir, '*')).each do |server|
          next unless File.directory?(server)
          server_name = File.basename(server)
          server_vendor_dir = File.join(vendor_dir, server_name)
          Formatron::Util::Berks.vendor(
            server,
            server_vendor_dir,
            true
          )
          opscode_s3_key = @config.config['formatronOpscodeS3Key']
          s3_key = "#{opscode_s3_key}/cookbooks/#{server_name}.tar.gz"
          response = @s3.put_object(
            bucket: @config.s3_bucket,
            key: s3_key,
            body: Formatron::Util::Tar.gzip(
              Formatron::Util::Tar.tar(server_vendor_dir)
            )
          )
        end
      else
        opscode_s3_key = "#{@target}/#{server_stack}/opscode"
        s3_key = "#{opscode_s3_key}/keys/#{@config.opscode.user}.pem"
        response = @s3.get_object(
          bucket: @config.s3_bucket,
          key: s3_key
        )
        user_key = response.body.read
        knife = Formatron::Util::Knife.new(
          @config.opscode.server_url,
          @config.opscode.user,
          user_key,
          @config.opscode.organization,
          @config.opscode.ssl_verify
        )
        berks = Formatron::Util::Berks.new(
          @config.opscode.server_url,
          @config.opscode.user,
          user_key,
          @config.opscode.organization,
          @config.opscode.ssl_verify
        )
        begin
          Dir.glob(File.join(opscode_dir, '*')).each do |server|
            next unless File.directory?(server)
            server_name = File.basename(server)
            environment_name = "#{@config.name}__#{server_name}"
            knife.create_environment environment_name
            berks.upload_environment server, environment_name
          end
        ensure
          berks.unlink
          knife.unlink
        end
      end
    end
    opsworks_dir = File.join(@dir, OPSWORKS_DIR)
    if File.directory?(opsworks_dir)
      vendor_dir = File.join(@dir, VENDOR_DIR)
      FileUtils.rm_rf vendor_dir
      Dir.glob(File.join(opsworks_dir, '*')).each do |stack|
        next unless File.directory?(stack)
        stack_name = File.basename(stack)
        stack_vendor_dir = File.join(vendor_dir, stack_name)
        Formatron::Util::Berks.vendor(
          stack,
          stack_vendor_dir
        )
        s3_key = @config.config['formatronOpsworksS3Key']
        response = @s3.put_object(
          bucket: @config.s3_bucket,
          key: "#{s3_key}/#{stack_name}.tar.gz",
          body: Formatron::Util::Tar.gzip(
            Formatron::Util::Tar.tar(stack_vendor_dir)
          )
        )
      end
    end
    cloudformation_dir = File.join(@dir, CLOUDFORMATION_DIR)
    return unless File.directory?(cloudformation_dir)
    cloudformation_pathname = Pathname.new cloudformation_dir
    main = nil
    # upload plain json templates
    Dir.glob(File.join(cloudformation_dir, '**/*.json')) do |template|
      template_pathname = Pathname.new template
      template_json = File.read template
      response = @cloudformation.validate_template(
        template_body: template_json
      )
      relative_path = template_pathname.relative_path_from(
        cloudformation_pathname
      )
      s3_key = @config.config['formatronCloudformationS3Key']
      response = @s3.put_object(
        bucket: @config.s3_bucket,
        key: "#{s3_key}/#{relative_path}",
        body: template_json
      )
      main = JSON.parse(template_json) if
        relative_path.to_s.eql?(MAIN_CLOUDFORMATION_JSON)
    end
    # process and upload erb templates
    Dir.glob(File.join(cloudformation_dir, '**/*.json.erb')) do |template|
      template_pathname = Pathname.new File.join(
        File.dirname(template),
        File.basename(template, '.erb')
      )
      erb = ERB.new(File.read(template))
      erb.filename = template
      erb_template = erb.def_class(TemplateParams, 'render()')
      template_json = erb_template.new(@config.config).render
      response = @cloudformation.validate_template(
        template_body: template_json
      )
      relative_path = template_pathname.relative_path_from(
        cloudformation_pathname
      )
      s3_key = @config.config['formatronCloudformationS3Key']
      response = @s3.put_object(
        bucket: @config.s3_bucket,
        key: "#{s3_key}/#{relative_path}",
        body: template_json
      )
      main = JSON.parse(template_json) if
        relative_path.to_s.eql?(MAIN_CLOUDFORMATION_JSON)
    end
    # rubocop:disable Metrics/LineLength
    cloudformation_s3_root_url = "https://s3.amazonaws.com/#{@config.s3_bucket}/#{@config.config['formatronCloudformationS3Key']}"
    # rubocop:enable Metrics/LineLength
    template_url = "#{cloudformation_s3_root_url}/#{MAIN_CLOUDFORMATION_JSON}"
    capabilities = ['CAPABILITY_IAM']
    main_keys = main['Parameters'].keys
    parameters = main_keys.map do |key|
      if %w(
        formatronName
        formatronTarget
        formatronPrefix
        formatronS3Bucket
        formatronRegion
        formatronKmsKey
        formatronConfigS3Key
        formatronCloudformationS3Key
        formatronOpsworksS3Key
        formatronOpscodeS3Key
      ).include?(key)
        {
          parameter_key: key,
          parameter_value: @config.config[key],
          use_previous_value: false
        }
      else
        fail(
          "No value specified for parameter: #{key}"
        ) if
          @config.cloudformation.nil? ||
          @config.cloudformation.parameters[key].nil?
        {
          parameter_key: key,
          parameter_value: @config.cloudformation.parameters[key].to_s,
          use_previous_value: false
        }
      end
    end
    begin
      response = @cloudformation.create_stack(
        stack_name: "#{@config.prefix}-#{@config.name}-#{@target}",
        template_url: template_url,
        capabilities: capabilities,
        on_failure: 'DO_NOTHING',
        parameters: parameters
      )
    rescue Aws::CloudFormation::Errors::AlreadyExistsException
      begin
        response = @cloudformation.update_stack(
          stack_name: "#{@config.prefix}-#{@config.name}-#{@target}",
          template_url: template_url,
          capabilities: capabilities,
          parameters: parameters
        )
      rescue Aws::CloudFormation::Errors::ValidationError => error
        raise error unless error.message.eql?(
          'No updates are to be performed.'
        )
      end
      # TODO: wait for the update to finish and
      # then update the opsworks stacks
    end
  end
end
