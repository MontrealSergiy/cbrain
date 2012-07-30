
#
# CBRAIN Project
#
# Copyright (C) 2008-2012
# The Royal Institution for the Advancement of Learning
# McGill University
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.  
#

# This class provides the functionality necessary to create,
# destroy and manage persistent SSH agents.
#
# Original author: Pierre Rioux

require 'fcntl'
require 'rubygems'
require 'sys/proctable'
require 'active_support'

# This class manages a set of ssh-agent processes, mostly by
# encapsulating the two variables that allows the 'ssh-add'
# command to connect to them: SSH_AUTH_SOCK and SSH_AGENT_PID.
#
# Each ssh-agent process is given a simple identifier as a name.
# They are persistent accross multiple Ruby processes, and even
# when the Ruby processes exit. These are called 'named agents'
# and their parameters (the values of the environment variables)
# are stored in small files in BASH format.
#
# The class is also capable of detecting and recording
# a single forwarded agent.
#
# == Attributes
#
# *name* The name of the agent
#
# *pid* The ID of the ssh-agent process
#
# *socket* The path to the UNIX-domain socket to connect to the agent
#
# Note that the forwarded agent (discussed below) doesn't have
# a pid, and its name is always '_forwarded'.
#
# == Creating an agent
#
# This will spawn a new ssh-agent process and store its
# connection information under the name 'myname'.
#
#   agent = SshAgent.create('myname')
#
# Once created, a config file containing the environment variables
# that represent this agent will be created. The path of
# this file can be obtained with agent_bash_config_file_path().
#
# == Finding an existing agent
#
# This will return an agent previously created by create(),
# even by another Ruby process.
#
#   agent = SshAgent.find_by_name('myname')
#
# == Finding a forwarded agent
#
# If a SSH connection provided the current process with
# a forwarding socket for a remote agent, then this method
# will find it:
#
#   agent = SshAgent.find_forwarded
#
# Once found, such an agent can then again be obtained with
# the name '_forwarded' using the find_by_name() method.
# Just like for the method create(), a config file can also
# be obtained with agent_bash_config_file_path().
#
class SshAgent

  #include Sys  # for ProcTable  TODO

  Revision_info=CbrainFileRevision[__FILE__]

  CONFIG = {
    :agent_bashrc_dir => (Rails.root rescue nil) ? "#{Rails.root.to_s}/tmp" : "/tmp",
    :hostname         => Socket.gethostname,
  }

  attr_reader :name, :pid, :socket

  def initialize(name,socket=nil,pid=nil) #:nodoc:
    raise "Invalid name" unless name =~ /^[a-z]\w*$/i || name == '_forwarded'
    @name   = name
    @socket = socket.present? ? socket.to_s : nil
    @pid    = pid.present?    ? pid.to_s    : nil
  end


  #----------------------------
  # Finder methods, class level
  #----------------------------

  # If no +name+ is given, does a find_forwarded().
  # With a +name+, does a find_by_name(name).
  def self.find(name=nil)
    name.present? ? self.find_by_name(name) : self.find_forwarded
  end

  # Finds a previously created named agent called +name+.
  # The info about the agent is read back from a config
  # file, and so it is possible that the agent is no longer
  # existing.
  def self.find_by_name(name)
    conf_file    = agent_config_file_path(name)
    return nil unless File.file?(conf_file)
    socket,pid   = read_agent_config_file(conf_file)
    return nil unless socket.present? && File.socket?(socket)
    self.new(name,socket,pid)
  end

  # Checks the current environment to see if it corresponds
  # to a state where a forwarded agent is available; if so
  # it will return an agent object to represent it and store
  # its info in a config file just like if it had been
  # created with the name '_forwarded'.
  def self.find_forwarded
    socket = ENV['SSH_AUTH_SOCK']
    return self.find_by_name('_forwarded') unless socket.present? && File.socket?(socket)
    agent_pid = ENV['SSH_AGENT_PID']
    return self.find_by_name('_forwarded') if agent_pid.present? # there is no ssh-agent process if it's forwarded
    agent = self.new('_forwarded', socket, nil)
    agent.write_agent_config_file
    agent
  end

  # Creates a new SshAgent object representing a launched
  # ssh-agent process, associated with the +name+. If a
  # process already seems to exists, raise an exception.
  def self.create(name)
    exists = self.find_by_name(name)
    raise "Agent named '#{name}' already exists." if exists
    agent_out  = IO.popen("ssh-agent -s","r") { |fh| fh.read }
    socket,pid = parse_agent_config_file(agent_out)
    agent      = self.new(name, socket, pid)
    agent.write_agent_config_file
    agent
  end

  # This attempts to find_by_name(), and if this fails it
  # invokes create().
  def self.find_or_create(name)
    self.find_by_name(name) || self.create(name)
  end



  #-----------------------
  # Agent instance methods
  #-----------------------

  # When invoked with no block given, sets the environment in
  # the current Ruby process so that SSH_AUTH_SOCK and SSH_AGENT_PID
  # corresponds to the agent. Returns true.
  #
  # When invoked with a block, temporarily change the environment
  # with these two variables and runs the block in the changed
  # environment. Returns what the block returns.
  def apply
    if block_given?
      return with_modified_env('SSH_AUTH_SOCK' => self.socket, 'SSH_AGENT_PID' => self.pid) { yield }
    end
    ENV['SSH_AUTH_SOCK'] = self.socket.present? ? self.socket.to_s : nil
    ENV['SSH_AGENT_PID'] = self.pid.present?    ? self.pid.to_s    : nil
    true
  end

  # Checks that the agent is alive and responding.
  def is_alive?
    return false unless self.socket.present? && File.socket?(self.socket)
    with_modified_env('SSH_AUTH_SOCK' => self.socket, 'SSH_AGENT_PID' => self.pid) do
      out = IO.popen("ssh-add -l 2>&1","r") { |fh| fh.read }
      # "1024 9e:8a:9b:b5:33:4e:e5:b6:f1:e1:7a:82:47:de:d2:38 /Users/prioux/.ssh/id_dsa (DSA)"
      # "Could not open a connection to your authentication agent."
      return false if     out =~ /could not open/i
      return true  if     out =~ /agent has no identities/i
      return false unless out =~ /:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:/
      true
    end
  end

  # Does a is_alive?() check; if it succeeds, returns the agent;
  # otherwise does a destroy() and returns nil. Can be used just
  # after a find:
  #
  #   agent = SshAgent.find_by_name('abcd').try(:aliveness)
  #   agent = SshAgent.find_forwarded.try(:aliveness)
  #
  def aliveness
    return self if self.is_alive?
    self.destroy rescue nil
    nil
  end

  # Adds a private key stored in file +keypath+ in the agent.
  # Raises an exception if the 'ssh-add' command complains.
  def add_key_file(keypath = "#{ENV['HOME']}/.ssh/id_rsa")
    out = IO.popen("ssh-add #{keypath.to_s.bash_escape} 2>&1","r") { |fh| fh.read }
    raise "Key file doesn't exist, is invalid, or has improper permission" unless out =~ /^Identity added/i
    true
  end

  # Stops the agent, removes the socket file, remove
  # the agent's config file.
  def destroy
    if self.pid.present?
      Process.kill('TERM',self.pid.to_i) rescue nil
      ENV['SSH_AGENT_PID'] = nil if ENV['SSH_AGENT_PID'] == self.pid
      @pid = nil
    end
    if self.name.present? && self.name != '_forwarded'
      File.unlink(self.agent_bash_config_file_path)
      @name = '_destroyed_'
      ENV['SSH_AUTH_SOCK'] = nil if ENV['SSH_AUTH_SOCK'] == self.socket
      File.unlink(self.socket) rescue nil
      @socket = nil
    end
    true
  end



  #---------------------
  # Config file methods
  #---------------------

  # Returns a path to a BASH script containing the
  # settings for the ssh-agent process (or the
  # forwarded agent).
  def agent_bash_config_file_path
    self.class.agent_config_file_path(self.name)
  end

  def write_agent_config_file #:nodoc:
    umask = File.umask(0077)
    filename = self.class.agent_config_file_path(self.name)
    File.open(filename,"w") do |fh|
      fh.write(<<-AGENT_CONF)
# File created automatically by SshAgent rev. #{self.revision_info.to_s.svn_id_pretty_rev_author_date}
# This script is in bash format and corresponds more or less to
# the output of the 'ssh-agent -s' command.
# This agent is named '#{self.name}'.
SSH_AUTH_SOCK=#{self.socket}; export SSH_AUTH_SOCK;
SSH_AGENT_PID=#{self.pid}; export SSH_AGENT_PID;
echo Agent pid #{self.pid};
      AGENT_CONF
    end
  ensure
    File.umask(umask) rescue true
  end

  def self.agent_config_file_path(name) #:nodoc:
    raise "Agent name is not a simple identifier." unless name.present? && (name =~ /^[a-z]\w*$/i || name == '_forwarded')
    Pathname.new(CONFIG[:agent_bashrc_dir]) + "#{name}@#{CONFIG[:hostname]}.agent.bashrc"
  end



  private

  def self.read_agent_config_file(filename) #:nodoc:
    content = File.read(filename)
    parse_agent_config_file(content)
  end

  def self.parse_agent_config_file(content) #:nodoc:
    sockpath = (content =~ /SSH_AUTH_SOCK=([^;\s]+)/) && Regexp.last_match[1]
    agentpid = (content =~ /SSH_AGENT_PID=([^;\s]+)/) && Regexp.last_match[1]
    return sockpath, agentpid
  end

end
