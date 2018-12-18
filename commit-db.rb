#!/usr/bin/env ruby
#
# Maintain a database of Rust compiler versions and the git commit that they
# were built from.
#
# (C) Copyright 2016 Jethro G. Beekman
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License as published by the
# Free Software Foundation, either version 3 of the License, or (at your
# option) any later version.

require 'json'
require 'net/https'
require 'aws-sdk-s3'

class BbotCache
	def initialize(channel)
		@channel=channel
		fixups=JSON.load(IO.read(fixups_file))
		@builds=Hash[Dir.foreach(cache_dir).map { |entry|
			next unless entry=~/^\d+$/
			data=JSON.load(IO.read("#{cache_dir}/#{entry}"))
			commit=(data['properties'].find{|p|p[0]=="got_revision"}||[])[1]
			if fixups.include?commit then
				data['properties']+=fixups[commit].map{|k,v|[k,v,"FIXUP"]}
			end
			[entry.to_i,data]
		}.compact.sort_by{|a|a[0]}]
	end

	def update(force=false)
		return unless force || (File.mtime(cache_dir) <= (Time.now-86400))

		$stderr.puts "Checking for buildbot updates on #{@channel}"
		info=Net::HTTP.get(URI("https://buildbot.rust-lang.org/json/builders/#{@channel}-dist-rustc-linux"))
		raise IOError, "Unable to obtain builder info" if info.nil?

		missing=JSON.load(info)['cachedBuilds']-@builds.keys
		return if missing.length==0

		$stderr.puts "Retrieving build(s) #{missing*","} from #{@channel}"
		query=missing.map{|i|"select=#{i}"}*"&"
		data=Net::HTTP.get(URI("https://buildbot.rust-lang.org/json/builders/#{@channel}-dist-rustc-linux/builds/?#{query}"))
		raise IOError, "Unable to obtain build info" if data.nil?

		JSON.load(data).each do |k,v|
			next if (v['text']&['successful','failed','exception']).length==0
			@builds[k.to_i]=v
			IO.write("#{cache_dir}/#{k}",JSON.dump(v))
		end

		File.utime(Time.now,Time.now,cache_dir)
	end

	def print
		@builds.each { |k,v|
			next if v['text']!=%w(build successful)
			p build_props(v)
		}
	end

	def valid_revisions
		@builds.map { |k,v|
			next if v['text']!=%w(build successful)
			props=build_props(v)
			if @channel=="stable" then
				next if props["package_name"].nil?
			else
				next if props["archive_date"].nil?
			end
			props['got_revision']
		}.compact
	end

	def lookup_by_commit(commit)
		@builds.select{|k,v|
			next if v['text']!=%w(build successful)
			v['properties'].find{|p|p[0]=='got_revision'&&p[1].start_with?(commit)}
		}.map{|k,v|
			props=build_props(v)
			if @channel=="stable" then
				props["package_name"]
			else
				next if props["archive_date"].nil?
				"#{@channel}-#{props["archive_date"]}"
			end
		}.compact
	end
	
	def latest
		for k in @builds.keys.sort.reverse do
			v=@builds[k]
			next if v['text']!=%w(build successful)
			props=build_props(v)
			if @channel=="stable" then
				next if props["package_name"].nil?
				return props["package_name"]
			else
				next if props["archive_date"].nil?
				return props["archive_date"]
			end
		end
	end

	def check_missing(index)
		if @channel=="stable" then
			index_versions=index.lines.map{|l|l=~Regexp.new("^/dist/rustc-(\\d+\\.\\d+\\.\\d+)-src.tar.gz,")&&$~[1]}.compact
			cache_versions=@builds.values.map{|v|build_props(v)['package_name']}.compact
			(index_versions-cache_versions).sort_by{|v|v.split(/[^0-9]+/).map(&:to_i)}
		else
			index_dates=index.lines.map{|l|l=~Regexp.new("^/dist/(\\d{4}-\\d{2}-\\d{2})/channel-rust-#{@channel}-date.txt,")&&$~[1]}.compact
			cache_dates=@builds.values.map{|v|build_props(v)['archive_date']}.compact
			(index_dates-cache_dates).sort_by{|v|v.split(/[^0-9]+/).map(&:to_i)}
		end
	end
private
	def build_props(build)
		props=Hash[%w(archive_date package_name got_revision).zip([])]
		build['properties'].each{|k,v,_|props[k]=v if props.include?k}
		props['channel']=@channel
		props
	end

	def cache_dir
		"bbot_json_cache/#{@channel}"
	end

	def fixups_file
		"fixups/#{@channel}"
	end
end

def resolve_commit(short_commit)
	if ENV.include?('GIT_DIR') then
		c=IO.popen(["git","rev-parse",short_commit],&:read)
		raise "git returned error: "+c if $?.exitstatus != 0
		c.strip
	else
		uri=URI("https://api.github.com/repos/rust-lang/rust/commits/#{short_commit}")
		resp=Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') { |http| http.get(uri, :Accept => 'application/vnd.github.VERSION.sha') }
		raise "GitHub returned error: "+resp.body if resp.code != 200
		resp.body
	end
end

class CommitCache
	def initialize
		@cache=IO.foreach(cache_file).map(&:strip).to_a
		@dirty=false
	end

	def lookup(short_commit)
		i = @cache.bsearch_index { |lc| short_commit <= lc }
		if i.nil? || !@cache[i].start_with?(short_commit) then
			i||=@cache.count
			lc=resolve_commit(short_commit)
			@cache.insert(i,lc)
			@dirty=true
			lc
		else
			@cache[i]
		end
	end

	def save
		if @dirty
			IO.write(cache_file,@cache.map{|s|s+"\n"}*"")
		end
	end

	def self.instance
		@@instance
	end

private
	def cache_file
		"commit_cache"
	end

	@@instance ||= CommitCache.new
	private_class_method :new
end

class DistCache
	def initialize(channel)
		@channel=channel

		if @channel=="stable" then
			glob="#{cache_dir}/*.toml"
			re=/\/channel-rust-(\d+\.\d+\.\d+)\.toml-version = "([^"]+)"$/
			dists=rg_versions(glob,re).map{|m|[m[1],m[2]]}
		else
			glob="#{cache_dir}/*/channel-rust-#{@channel}.toml"
			re=Regexp.new("/(\\d{4}-\\d{2}-\\d{2})/channel-rust-#{@channel}\.toml-version = \"([^\"]+)\"$")
			dists=rg_versions(glob,re).map{|m|["#{@channel}-#{m[1]}",m[2]]}
		end

		@dists=Hash[dists.map{|k,v|
			if /^\S+ \((\h{9}) \d{4}-\d{2}-\d{2}\)$/=~v then
				v=CommitCache.instance.lookup($~[1])
			else
				$stderr.puts "Error parsing version: #{version}"
				next
			end
			[k,v]
		}.compact]
	end

	def rg_versions(glob,re)
		IO.popen(["rg","-F","-A1","-N","--no-heading","[pkg.rust]","--glob",glob]).each_line.map {|l| $~ if re=~l }.compact
	end

	def update(force)
		$stderr.puts "Checking for release updates on #{@channel}"

		client = Aws::S3::Client.new(endpoint: 'https://static.rust-lang.org', region: 'none')
		client.list_objects_v2(bucket: '', prefix: 'dist/')

		tomls = []
		if @channel=="stable" then
			start_after = 'dist/channel-rust'
			break_re = '^dist/channel-rust'
			toml_re = '^dist/(channel-rust-\\d+\\.\\d+\\.\\d+\\.toml)$'
		else
			latest =~ Regexp.new("^#{@channel}-(\\d{4}-\\d{2}-\\d{2})$")

			if force then
				start_after = 'dist/2000-01-01'
			else
				start_after = "dist/#{$~[1]}"
			end
			break_re = '^dist/\\d{4}-\\d{2}-\\d{2}/'
			toml_re = "^dist/(\\d{4}-\\d{2}-\\d{2}/channel-rust-#{@channel}\\.toml)$"
		end
		for obj in client.list_objects_v2(bucket: '', prefix: 'dist/', start_after: start_after)
					.each_page.lazy.flat_map { |page| page.data.contents }
			break unless obj.key =~ Regexp.new(break_re)
			tomls << $~[1] if obj.key =~ Regexp.new(toml_re)
		end

		count=0
		tomls.each do |toml|
			f="#{cache_dir}/#{toml}"
			if not File.exists?(f) then
				count+=1
				begin
					Dir.mkdir(File.dirname(f))
				rescue Errno::EEXIST
				end
				data=Net::HTTP.get(URI("#{url_base}/#{toml}"))
				raise IOError, "Unable to obtain release info" if data.nil?
				IO.write(f,data)
			end
		end
		$stderr.puts "Retrieved #{count} new releases"

		initialize(@channel) if count>0

		File.utime(Time.now,Time.now,cache_dir)
	end

	def valid_revisions
		@dists.values
	end

	def lookup_by_commit(commit)
		commit=CommitCache.instance.lookup(commit)
		@dists.select{|k,v|v==commit}.map{|k,v|k}.to_a
	end

	def latest
		@dists.keys.sort.reverse[0]
	end
private
	def cache_dir
		"dist_toml_cache"
	end

	def url_base
		"https://static.rust-lang.org/dist"
	end
end

if !%w(lookup list-valid update).include?ARGV[0] then
	$stderr.puts "Usage:"
	$stderr.puts "	commit-db update [--force]"
	$stderr.puts "	commit-db list-valid CHANNEL"
	$stderr.puts "	commit-db lookup COMMIT"
	exit(1)
end

Dir.chdir(File.dirname(__FILE__))

case ARGV[0]
when 'update'
	['beta','stable','nightly'].each do |channel|
		dcache=DistCache.new(channel)
		dcache.update(ARGV[1]=='--force')
		$stderr.puts "Latest dist nightly: #{dcache.latest}" if channel=='nightly'
		#bcache=BbotCache.new(channel)
		#bcache.update(ARGV[1]=='--force')
		#missing=bcache.check_missing(index)
		#puts "Missing buildbot versions for #{channel}: #{missing*", "}" if missing.length>0
		#$stderr.puts "Latest buildbot nightly: #{bcache.latest}" if channel=='nightly'
	end
when 'lookup'
	['nightly','beta','stable'].each do |channel|
		bcache=BbotCache.new(channel)
		dcache=DistCache.new(channel)
		puts (bcache.lookup_by_commit(ARGV[1])+dcache.lookup_by_commit(ARGV[1])).uniq
	end
when 'list-valid'
	bcache=BbotCache.new(ARGV[1])
	dcache=DistCache.new(ARGV[1])
	puts (bcache.valid_revisions+dcache.valid_revisions).uniq
end

CommitCache.instance.save
