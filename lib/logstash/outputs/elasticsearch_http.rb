require "logstash/namespace"
require "logstash/outputs/base"

# This output lets you store logs in elasticsearch.
#
# This plugin uses the HTTP/REST interface to ElasticSearch, which usually
# lets you use any version of elasticsearch server. It is known to work
# with elasticsearch %ELASTICSEARCH_VERSION%
#
# You can learn more about elasticsearch at <http://elasticsearch.org>
class LogStash::Outputs::ElasticSearchHTTP < LogStash::Outputs::Base

  config_name "elasticsearch_http"
  plugin_status "beta"

  # The index to write events to. This can be dynamic using the %{foo} syntax.
  # The default value will partition your indices by day so you can more easily
  # delete old data or only search specific date ranges.
  config :index, :validate => :string, :default => "logstash-%{+YYYY.MM.dd}"

  # The index type to write events to. Generally you should try to write only
  # similar events to the same 'type'. String expansion '%{foo}' works here.
  config :index_type, :validate => :string, :default => "%{@type}"

  # The hostname or ip address to reach your elasticsearch server.
  config :host, :validate => :string

  # The port for ElasticSearch HTTP interface to use.
  config :port, :validate => :number, :default => 9200

  # Set the number of events to queue up before writing to elasticsearch.
  #
  # If this value is set to 1, the normal ['index
  # api'](http://www.elasticsearch.org/guide/reference/api/index_.html).
  # Otherwise, the [bulk
  # api](http://www.elasticsearch.org/guide/reference/api/bulk.html) will
  # be used.
  config :flush_size, :validate => :number, :default => 100

  # The document ID for the index. Useful for overwriting existing entries in
  # elasticsearch with the same ID.
  config :document_id, :validate => :string, :default => nil

  # Enable SSL (you need elasticsearch-jetty set up with SSL)
  # https://github.com/sonian/elasticsearch-jetty#adding-ssl-support
  # NOTE: Elasticsearch must be set up with a signed cert from a trusted CA
  config :secure, :validate => :boolean, :default => false

  # Use basic auth with elastic search. You need elasticsearch-jetty
  # with the basic auth setup.
  config :http_auth, :validate => :boolean, :default => false

  # The username/password for http basic auth
  config :http_user, :validate => :string, :default => nil
  config :http_pass, :validate => :string, :default => nil

  public
  def register
    require "ftw" # gem ftw
    @agent = FTW::Agent.new
    @queue = []

  end # def register

  public
  def receive(event)
    return unless output?(event)

    index = event.sprintf(@index)
    type = event.sprintf(@index_type)

    if @flush_size == 1
      receive_single(event, index, type)
    else
      receive_bulk(event, index, type)
    end #
  end # def receive

  def receive_single(event, index, type)
    success = false
    while !success
      begin
        if @secure
          if @http_auth
            response = @agent.post!("https://#{@http_user}:#{@http_pass}@#{@host}:#{@port}/#{index}/#{type}",
                                    :body => event.to_json)
          else
            response = @agent.post!("https://#{@host}:#{@port}/#{index}/#{type}",
                                    :body => event.to_json)
          end
        else
          if @http_auth
            response = @agent.post!("http://#{@http_user}:#{@http_pass}@#{@host}:#{@port}/#{index}/#{type}",
                                    :body => event.to_json)
          else
            response = @agent.post!("http://#{@host}:#{@port}/#{index}/#{type}",
                                    :body => event.to_json)
          end
        end
      rescue EOFError
        @logger.warn("EOF while writing request or reading response header from elasticsearch",
                     :host => @host, :port => @port)
        next # try again
      end


      begin
        # We must read the body to free up this connection for reuse.
        body = "";
        response.read_body { |chunk| body += chunk }
      rescue EOFError
        @logger.warn("EOF while reading response body from elasticsearch",
                     :host => @host, :port => @port)
        next # try again
      end

      if response.status != 201
        @logger.error("Error writing to elasticsearch",
                      :response => response, :response_body => body)
      else
        success = true
      end
    end
  end # def receive_single

  def receive_bulk(event, index, type)
    header = { "index" => { "_index" => index, "_type" => type } }
    if !@document_id.nil?
      header["index"]["_id"] = event.sprintf(@document_id)
    end
    @queue << [
      header.to_json, event.to_json
    ].join("\n")

    # Keep trying to flush while the queue is full.
    # This will cause retries in flushing if the flush fails.
    flush while @queue.size >= @flush_size
  end # def receive_bulk

  def flush
    @logger.debug? && @logger.debug("Flushing events to elasticsearch",
                                    :count => @queue.count)
    # If we don't tack a trailing newline at the end, elasticsearch
    # doesn't seem to process the last event in this bulk index call.
    #
    # as documented here:
    # http://www.elasticsearch.org/guide/reference/api/bulk.html
    #  "NOTE: the final line of data must end with a newline character \n."
    begin
      if @secure
        if @http_auth
          response = @agent.post!("https://#{@http_user}:#{@http_pass}@#{@host}:#{@port}/_bulk",
                                  :body => @queue.join("\n") + "\n")
        else
          response = @agent.post!("https://#{@host}:#{@port}/_bulk",
                                  :body => @queue.join("\n") + "\n")
        end
      else
        if @http_auth
          response = @agent.post!("http://#{@http_user}:#{@http_pass}@#{@host}:#{@port}/_bulk",
                                  :body => @queue.join("\n") + "\n")
        else
          response = @agent.post!("http://#{@host}:#{@port}/_bulk",
                                  :body => @queue.join("\n") + "\n")
        end
      end
    rescue EOFError
      @logger.warn("EOF while writing request or reading response header from elasticsearch",
                   :host => @host, :port => @port)
      return # abort this flush
    end

    # Consume the body for error checking
    # This will also free up the connection for reuse.
    body = ""
    begin
      response.read_body { |chunk| body += chunk }
    rescue EOFError
      @logger.warn("EOF while reading response body from elasticsearch",
                   :host => @host, :port => @port)
      return # abort this flush
    end

    if response.status != 200
      @logger.error("Error writing (bulk) to elasticsearch",
                    :response => response, :response_body => body,
                    :request_body => @queue.join("\n"))
      return
    end

    # Clear the queue on success only.
    @queue.clear
  end # def flush

  def teardown
    flush while @queue.size > 0
  end # def teardown

  # THIS IS NOT USED YET. SEE LOGSTASH-592
  def setup_index_template
    template_name = "logstash-template"
    template_wildcard = @index.gsub(/%{[^}+]}/, "*")
    template_config = {
      "template" => template_wildcard,
      "settings" => {
        "number_of_shards" => 5,
        "index.compress.stored" => true,
        "index.query.default_field" => "@message"
      },
      "mappings" => {
        "_default_" => {
          "_all" => { "enabled" => false }
        }
      }
    } # template_config

    @logger.info("Setting up index template", :name => template_name,
                 :config => template_config)
    begin
      success = false
      while !success
        if @secure
          if @http_auth
            response = @agent.put!("https://#{@http_user}:#{@http_pass}@#{@host}:#{@port}/_template/#{template_name}",
                                   :body => template_config.to_json)
          else
            response = @agent.put!("https://#{@host}:#{@port}/_template/#{template_name}",
                                   :body => template_config.to_json)
          end
        else
          if @http_auth
            response = @agent.put!("http://#{@http_user}:#{@http_pass}@#{@host}:#{@port}/_template/#{template_name}",
                                   :body => template_config.to_json)
          else
            response = @agent.put!("http://#{@host}:#{@port}/_template/#{template_name}",
                                   :body => template_config.to_json)
          end
        end
        if response.error?
          body = ""
          response.read_body { |c| body << c }
          @logger.warn("Failure setting up elasticsearch index template, will retry...",
                       :status => response.status, :response => body)
          sleep(1)
        else
          success = true
        end
      end
    rescue => e
      @logger.warn("Failure setting up elasticsearch index template, will retry...",
                   :exception => e)
      sleep(1)
      retry
    end
  end # def setup_index_template
end # class LogStash::Outputs::ElasticSearchHTTP
