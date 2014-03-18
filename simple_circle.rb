require "sinatra"
require "net/https"
require "uri"
require "yaml"
require "json"
require "fileutils"

class SimpleCircleConfig
  def self.load_config
    YAML.load(File.read("./config.yml"))
  end

  def self.[](key)
    @config ||= load_config
    @config[key.to_s]
  end
end

class Artifact
  def initialize(options = {})
    @url        = options["url"]
    @path       = options["path"]
    @filename   = File.basename(@path)
    @node_index = options["node_index"]
  end

  def fetch!(if_match = /\.json/)
    return nil unless @filename =~ if_match

    path = "./tmp/#{@node_index}/coverage/"
    path_with_filename = "#{path}#{@filename}"

    uri = URI.parse("#{@url}?circle-token=#{SimpleCircleConfig[:api_token]}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    request = Net::HTTP::Get.new(uri.request_uri)
    request.add_field("Accept", "application/json")

    response = http.request(request)

    FileUtils.mkdir_p(path)
    File.write(path_with_filename, response.body)
  end
end

class Array
  def simplecov_merge(other)
    each_with_index do |entry, index|
      if entry.nil? && other[index].nil?
      elsif entry.nil? && !other[index].nil?
        self[index] = other[index]
      elsif !entry.nil? && !other[index].nil?
        self[index] += other[index]
      end
    end
  end
end

class MultiSet
  def initialize
    require "simplecov"

    json_files = Dir['./tmp/**/**/.resultset.json']

    (class << File; self; end).class_eval %Q{
      alias_method :original_open, :open
      def open(*args)
      end
    }

    results = json_files.map do |coverage_file|
      file = File.read(coverage_file)
      json = SimpleCov::JSON.parse(file)

      result = SimpleCov::Result.new(json["RSpec"]["coverage"])
    
      mock_files = SimpleCov::FileList.new(json["RSpec"]["coverage"].map { |filename, coverage|
        mock_file = SimpleCov::SourceFile.new(filename, coverage) 
        mock_file.send(:instance_variable_set, "@src", coverage.map {|c| "MOCKED: #{c}"})
        mock_file
      }.compact.sort_by(&:filename))

      result.send(:instance_variable_set, "@files", mock_files)
      result.command_name = 'RSpec'

      result
    end

    (class << File; self; end).class_eval %Q{
      alias_method :open, :original_open
    }

    merged_result = results[0]
    results[1..-1].each do |result|
      merged_result.original_result.map do |filename, lines| 
        if !result.original_result[filename].nil?
          merged_result.original_result[filename].simplecov_merge result.original_result[filename]
        end
      end
    end

    @result = merged_result
    @result
  end

  def format!
    @result.format!
  end
end


get '/:username/:project/:build' do
  start= Time.now

  FileUtils.rm_rf("./coverage")
  FileUtils.rm_rf("./tmp")

  uri = URI.parse("https://circleci.com/api/v1/project/#{params[:username]}/#{params[:project]}/#{params[:build]}/artifacts?circle-token=#{SimpleCircleConfig[:api_token]}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE

  request = Net::HTTP::Get.new(uri.request_uri)
  request.add_field("Accept", "application/json")

  response = http.request(request)
  response_json = JSON.parse(response.body)
  artifacts = response_json.map {|artifact| Artifact.new(artifact)}

  artifacts.map(&:fetch!)

  multi = MultiSet.new

  multi.format!
  
  redirect to('/coverage/index')
end

get '/coverage/index' do
  File.read(File.join('coverage', 'index.html'))
end

get '/coverage/*.*' do |path, ext|
  case ext
  when /\.js/
    content_type :js
  when /\.png/
    content_type :png
  when /\.gif/
    content_type :gif
  when /\.css/
    content_type :css
  else
    content_type :html
  end
    
  File.read(File.join('coverage', "#{path}.#{ext}"))
end
