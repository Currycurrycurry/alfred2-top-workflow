#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

# ============== = ===========================================================
# Description    : Alfred 2 Top Processes Workflow
# Author         : Zhao Cai <caizhaoff@gmail.com>
# HomePage       : https://github.com/zhaocai/alfred2-top-workflow
# Date Created   : Sun 10 Mar 2013 09:59:48 PM EDT
# Last Modified  : Sat 30 Mar 2013 11:39:10 PM EDT
# Tag            : [ ruby, alfred, workflow ]
# Copyright      : © 2013 by Zhao Cai,
#                  Released under current GPL license.
# ============== = ===========================================================

($LOAD_PATH << File.expand_path("..", __FILE__)).uniq!

require 'rubygems' unless defined? Gem # rubygems is only needed in 1.8

require "bundle/bundler/setup"
require "alfred"

# require handler class on demand
require 'alfred/handler/callback'

require 'mixlib/shellout'


class Integer
  def to_human
    units = ['', 'K', 'M', 'G', 'T', 'P']

    size, unit = units.reduce(self.to_f) do |(fsize, _), utype|
      fsize > 512 ? [fsize / 1024, utype] : (break [fsize, utype])
    end

    "#{size > 9 || size.modulo(1) < 0.1 ? '%d' : '%.1f'}%s" % [size, unit]
  end
end

class Top < ::Alfred::Handler::Base

  attr_accessor :ignored_processes, :vague_commands

  PS_State = {
    :main => {
      'I' => ':idle',
      'R' => ':runnable',
      'S' => ':sleep',
      'T' => ':stopped',
      'U' => ':uninterruptible',
      'Z' => ':zombie',
      '?' => ':unknown'
    },
    :additional => {
      '+' => 'foreground',
      '<' => 'raised priority',
      '>' => 'soft limit on memory',
      'A' => 'random page replacement',
      'E' => 'trying to exit',
      'L' => 'page locked',
      'N' => 'reduced priority',
      'S' => 'FIO page replacement',
      's' => 'session leader',
      'V' => 'suspended',
      'W' => 'swapped out',
      'X' => 'being traced or debugged'
    }
  }

  def initialize(alfred, opts = {})
    super
    @settings = {
      :handler    => 'Top'
    }.update(opts)

    # [TODO] load from @core.workflow_setting @zhaocai @start(2013-10-11)
    # Ignore mds because its cpu usgae spikes the moment alfred calls the workflow
    @ignored_processes = ['Alfred 2', 'mds']

    @vague_commands = [
      'ruby'     , 'java' , 'zsh', 'bash', 'python', 'perl', 'rsync',
      'macruby'  , 'ctags', 'vim', 'Vim' , 'MacVim', 'ag'  , 'node' , 'aria2c',
      'osascript'
    ]

    @io_sample_interval = 10
    @callback = ::Alfred::Handler::Callback.new(alfred)
    @callback.register
  end

  def on_parser
    options.sort = :auto
    parser.on("-m", "--memory", "sort by memory usage") do
      options.sort = :memory
    end
    parser.on("-c", "--cpu", "sort by cpu usage") do
      options.sort = :cpu
    end

    parser.on("-i", "--io", "sort by io usage") do
      options.sort = :io
    end
  end

  def on_help
    [
      {
        :kind         => 'text'                ,
        :title        => '-c, --cpu [query]'   ,
        :subtitle     => 'Sort top processes based on cpu ussage.' ,
        :autocomplete => "-c #{query}"
      },
      {
        :kind         => 'text'                   ,
        :title        => '-m, --memory [query]'   ,
        :subtitle     => 'Sort top processes based on memory ussage.' ,
        :autocomplete => "-m #{query}"
      },
      {
        :kind         => 'text'               ,
        :title        => '-i, --io [query]'   ,
        :subtitle     => 'Sort top processes based on io ussage.' ,
        :autocomplete => "-i #{query}"
      },
    ]
  end



  def generate_feedback(processes)
    processes.sort_by { |_, v| v[:rank] }.each do |pair|
      ps = pair[1]
      if ps[:icon]
        icon = ps[:icon]
      else
        icon = {:type => "default", :name => "icon/process/#{ps[:type]}.png"}
      end
      arg = xml_builder(
      :handler => @settings[:handler] ,
      :type    => ps[:type]           ,
      :pid     => ps[:pid]
      )

      feedback.add_item({
        :title    => ps[:title]         ,
        :subtitle => ps[:subtitle]      ,
        :arg      => arg               ,
        :icon     => icon              ,
        :match?   => :all_title_match? ,
      })
    end
  end


  def on_feedback
    case options.sort
    when :auto
      psm = list_processes(:memory)
      psc = list_processes(:cpu)

      processes = {}
      psc.each_pair do |id, p|
        m = psm[id]
        if m
          p[:type]  = :auto
          p[:title] =  "#{p[:rank]}/#{m[:rank]}: #{p[:command]}"
        end
        processes[id] = p
      end
      generate_feedback(processes)
    when :memory
      generate_feedback(list_processes(:memory))
    when :cpu
      generate_feedback(list_processes(:cpu))
    when :io
      arg = xml_builder(
        :handler => @settings[:handler] ,
        :task => 'callback',
        :type => 'iotop'
      )

      feedback.add_item({
        :title    => "Collect IO trace to show top IO usage?"        ,
        :subtitle => "Wait for callback after #{@io_sample_interval} seconds."       ,
        :icon     => ::Alfred::Feedback.CoreServicesIcon('GenericQuestionMarkIcon') ,
        :arg      => arg                                                            ,
      })
    end
  end

  def on_action(arg)
    return unless action?(arg)

    if arg[:task] == 'callback'
      case arg[:type]
      when 'iotop'

        generate_feedback(iotop)
        callback_entry = {
          :key => arg[:type],
          :title => "Top Workflow Callback",
          :subtitle => "IO Top",
        }

        @callback.on_callback('top', callback_entry, feedback.items )
      end

    else
      case options.modifier
      when :control
        run_and_message("kill #{arg[:pid]}")
      when :command
        run_and_message("kill -9 #{arg[:pid]}")
      when :alt
        run_and_message("renice -n 5 #{arg[:pid]}")
      when :none
        Alfred.search("lsof #{arg[:pid]}")
      end
    end
  end


  def iotop

    iosnoop_command = %q{./sudo.sh ./bin/iosnoop.d 2>/dev/null}
    iosnoop = Mixlib::ShellOut.new(iosnoop_command)
    iosnoop.timeout = @io_sample_interval

    ps = {}
    begin
      iosnoop.run_command
    rescue Mixlib::ShellOut::CommandTimeout
      iosnoop.stdout.each_line do |line|
        columns = line.split('⟩').map(&:strip)

        pid     = columns[0].to_i
        type    = columns[1]
        size    = columns[2].to_i
        command = columns[3]

        if ps.has_key?(pid)
          p = ps[pid]
        else
          p = {
            :pid        => pid     ,
            :type       => :io     ,
            :command    => command ,
            :read_size  => 0       ,
            :write_size => 0       ,
          }
        end

        case type
        when 'R'
          p[:read_size] += size
        when 'W'
          p[:write_size] += size
        end

        ps[pid] = p
      end
    end

    return [] if ps.empty?
    ranks = {}
    i = 1
    ps.sort_by { |_, p| p[:read_size] + p[:write_size] }.reverse.each do |pair|
      ranks[pair[0]] = i
      i += 1
    end
    ps.each do |_, p|
      if p[:pid] > 0
        command_line = interpret_command(p, :use_command_line => true).to_s

        m = command_line.match(/(.*\.app\/).*/)
        p[:icon] = {:type => "fileicon", :name => m[1]} if m
      end

      p[:rank] = ranks[p[:pid]]
      p[:title] = "#{p[:rank]}: #{p[:command]}"
      p[:subtitle] = "Read: #{p[:read_size].to_human} ↔ Write: #{p[:write_size].to_human}"
    end

    return ps
  end


  private

  def list_processes(type)

    type2opt = {:memory => 'm', :cpu => 'r'}

    cmd = %Q{ps -a#{type2opt[type]}wwwxo 'pid nice %cpu %mem state comm'}
    ps = Mixlib::ShellOut.new(cmd)
    ps.run_command

    lines = ps.stdout.lines.map(&:chomp)
    lines.shift

    processes = {}
    i = 1
    lines.each do |entry|
      columns = entry.split

      process = {
        :line    => entry      ,
        :type    => type       ,
        :rank    => i          ,
        :pid     => columns[0] ,
        :nice    => columns[1] ,
        :cpu     => columns[2] ,
        :memory  => columns[3] ,
        :state   => interpret_state(columns[4]) ,
        :command => columns[5..-1].join(" ")    ,
      }

      process[:icon] = {:type => "fileicon", :name => process[:command]}
      m = process[:command].match(/(.*\.app\/).*/)
      process[:icon][:name] = m[1] if m

      process[:command] = interpret_command(process)
      process[:title] = "#{process[:rank]}: #{process[:command]}"

      # Ignore this script
      unless process[:title].include?(__FILE__) || \
        @ignored_processes.include?(File.basename(process[:command]))
        processes[process[:pid]] = process
      end

      process[:subtitle] = "cpu: #{process[:cpu].rjust(6)}%,  " \
      "memory: #{process[:memory].rjust(6)}%,  "                \
      "nice:#{process[:nice].rjust(4)},  "                      \
      "state:(#{process[:pid].center(8)}) #{process[:state]}"

      i += 1
    end
    return processes
  end

  def interpret_command(process, opts = {})
    command = process[:command]
    command_basename = File.basename command

    if @vague_commands.include?(command_basename) || opts[:use_command_line]
      cmd = %Q{ps -awwwxo 'command' #{process[:pid]}}
      ps = Mixlib::ShellOut.new(cmd)
      ps.run_command

      if command_line = ps.stdout.lines.map(&:chomp)[1]
        if opts[:use_command_line]
          return command_line
        else
          return %Q{#{command_basename}#{command_line.sub(/^#{Regexp.escape(command)}/, '')}}
        end
      else
        return command_basename
      end
    else
      return command_basename
    end
  end

  def interpret_state(state)
    if state.empty?
      return ""
    end

    m = ""

    states = state.chars.to_a

    m = PS_State[:main][states.shift]
    a = []
    states.each { |c|
      a.push(PS_State[:additional][c])
    }

    if a.empty?
      return m
    else
      return "#{m}: #{a.join(',')}"
    end
  end

  def run_and_message(command, opts = {})
    kill = Mixlib::ShellOut.new(command, opts)
    kill.run_command
    puts status_message(command, kill.exitstatus)
  end
end







if __FILE__ == $PROGRAM_NAME

  Alfred.with_friendly_error do |alfred|
    alfred.with_rescue_feedback = true
    alfred.with_help_feedback = true

    Top.new(alfred).register
  end


end


# (#
# Modeline                                                                [[[1
# #)
# vim: set ft=ruby ts=2 sw=2 tw=78 fdm=marker fmr=[[[,]]] fdl=1 :
