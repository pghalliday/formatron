module Formatron::Features
  module Support
    class FormatronStackDefinition
      attr_accessor(
        :prefix,
        :name,
        :test_target,
        :test_param,
        :prod_target,
        :prod_param,
        :s3_bucket,
        :region,
        :test_kms_key,
        :prod_kms_key
      )

      def deploy(target)
        Dir.mktmpdir do |dir|
          Credentials.new dir
          Formatronfile.new dir, prefix, name, s3_bucket, region, test_target, test_kms_key, prod_target, prod_kms_key
          Config.new dir, test_target, test_param
          Config.new dir, prod_target, prod_param
          Cloudformation.new dir
          Formatron.new(dir, target).deploy
        end
      end
    end
  end
end
