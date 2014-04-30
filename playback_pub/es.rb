require 'stretcher'
require 'faraday_middleware'

module ES
  def self.server
    Thread.current[:es_connection] ||= Stretcher::Server.new(ENV['ELASTICSEARCH_URL'])
  end

  def self.index(index_name)
    server.index(index_name)
  end

  def self.update_index(index_name, options={})
    index(index_name).instance_eval do
      request(:put, "_settings", :index => options.reverse_merge(:refresh_interval => 10*1000,
                                                                 :number_of_replicas => 0))
    end
  end

  def self.create_index(index_name, options={})
    # number_of_replicas doesn't count master
    index(index_name).create(:index => options.reverse_merge(:refresh_interval => 10*1000,
                                                             :number_of_replicas => 1,
                                                             :number_of_shards => 18))
  rescue Stretcher::RequestError => e
    raise e unless e.http_response.body['error'] =~ /IndexAlreadyExistsException/
  end

  def self.delete_all_indexes
    index('*').delete
  end

  def self.update_all_mappings
    App.update_mapping(:_all)
    Source.update_mapping(:live)
  end

  class Model < Hashie::Dash
    alias_attribute :id, :_id

    def self.mapping
      @mapping ||= {}
    end

    def self.property(property_name, options={})
      super(property_name, :default => options.delete(:default), :required => options.delete(:required))
      # XXX Does not support nested objects yet.
      self.mapping[property_name] = options
    end

    def self.index(index_name)
      ES.index(index_name).type(self.name.underscore)
    end

    def self.update_mapping(index_name)
      mapping_options              = self.mapping.select { |k, v| k =~ /^_/ }
      mapping_options[:properties] = self.mapping.reject { |k, v| k =~ /^_/ }
      mapping_options[:_all] = { :enabled => false }
      index(index_name).put_mapping(self.name.underscore => mapping_options)
    end

    def self.find(index_name, id, options={})
      begin
        params = {:fields => options[:fields].join(',') } if options[:fields]
        new(index(index_name).instance_eval do
          result = request(:get, id, params)
          result['_source'] || result['fields']
        end)
      rescue Stretcher::RequestError::NotFound => e
        options[:no_raise] ? nil : raise(e)
      end
    end

    def save(index_name)
      self.class.index(index_name).put(self.id, self.reject { |k, v| v.nil? })
    rescue Faraday::Error::TimeoutError
      retry
    end
  end
end
