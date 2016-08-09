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

class BuildCache
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

		$stderr.puts "Checking for updates on #{@channel}"
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
			v['properties'].find{|p|p[0]=='got_revision'&&p[1]==commit}
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
	index=Net::HTTP.get(URI("https://static.rust-lang.org/dist/index.txt"))
	['beta','stable','nightly'].each do |channel|
		bcache=BuildCache.new(channel)
		bcache.update(ARGV[1]=='--force')
		missing=bcache.check_missing(index)
		puts "Missing buildbot versions for #{channel}: #{missing*", "}" if missing.length>0
		$stderr.puts "Latest nightly: #{bcache.latest}" if channel=='nightly'
	end
when 'lookup'
	['nightly','beta','stable'].each do |channel|
		bcache=BuildCache.new(channel)
		puts bcache.lookup_by_commit(ARGV[1])
	end
when 'list-valid'
	bcache=BuildCache.new(ARGV[1])
	puts bcache.valid_revisions
end


