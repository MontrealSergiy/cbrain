
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

# This model represents a tool's configuration prefix.
# Unlike other models, the set of ToolConfigs is not
# arbitrary. They fit in three categories:
#
# * A single tool config object represents the initialization
#   needed by a particular tool on all bourreaux; it
#   has a tool_id and no bourreau_id
# * A single tool config object represents the initialization
#   needed by a particular bourreau for all tools; it
#   has a bourreau_id and no tool_id
# * A set of 'versioning' tool config objects have both
#   a tool_id and a bourreau_id; they represent all
#   available versions of a tool on a particular bourreau.
class ToolConfig < ApplicationRecord

  Revision_info=CbrainFileRevision[__FILE__] #:nodoc:

  serialize       :env_array

  belongs_to      :bourreau, :optional => true     # can be nil; it means it applies to all bourreaux
  belongs_to      :tool, :optional => true         # can be nil; it means it applies to all tools
  has_many        :cbrain_tasks
  belongs_to      :group
  belongs_to      :container_image, :class_name => 'Userfile', :foreign_key => :container_image_userfile_id, :optional => true

  # Resource usage is kept forever even if tool config is destroyed.
  has_many        :resource_usage

  # first character must be alphanum, and can contain only alphanums, '.', '-', '_', ':' and '@'
  # must be unique per pair [tool, server]
  validates       :version_name,
                  :presence   => true,
                  :format     => { :with    => /\A\w[\w\.\-\:\@]*\z/,
                                   :message => "must begin with alphanum, and can contain only alphanums, '.', '-', '_', ':' and '@'" },
                  :uniqueness => { :scope   => [ :tool_id, :bourreau_id ],
                                   :message => "must be unique per pair [tool, server]" },
                  :if         => :applies_to_bourreau_and_tool?

  validate        :container_rules

  scope           :global_for_tools     , -> { where( { :bourreau_id => nil } ) }
  scope           :global_for_bourreaux , -> { where( { :tool_id => nil } ) }
  scope           :specific_versions    , -> { where( "bourreau_id is not null and tool_id is not null" ) }

  api_attr_visible :version_name, :description, :tool_id, :bourreau_id, :group_id, :ncpus

  # To make it somewhat compatible with the ResourceAccess module,
  # here's this model's own method for checking if it's visible to a user.
  def can_be_accessed_by?(user)
    return false unless self.group.can_be_accessed_by?(user)
    return false unless self.bourreau_and_tool_can_be_accessed_by?(user)
    true
  end

  # See ResourceAccess.
  def self.find_all_accessible_by_user(user) #:nodoc:
    if user.has_role?(:admin_user)
      ToolConfig.specific_versions
    else
      gids = user.group_ids
      bids = Bourreau.find_all_accessible_by_user(user).raw_first_column("remote_resources.id")
      tids = Tool.find_all_accessible_by_user(user).raw_first_column("tools.id")
      ToolConfig.specific_versions.where(:group_id => gids, :bourreau_id => bids, :tool_id => tids)
    end
  end

  # Returns true if both the bourreau and the tool associated
  # with the tool_config are defined and can be accessed by the user.
  def bourreau_and_tool_can_be_accessed_by?(user)
    self.bourreau && self.bourreau.can_be_accessed_by?(user) &&
    self.tool     && self.tool.can_be_accessed_by?(user)
  end

  # Returns the verion name or the first line of the description.
  # This is used to represent the 'name' of the version.
  def short_description
    description = self.description || ""
    raise "Internal error: can't parse description!?!" unless description =~ /\A(.+\n?)/ # the . doesn't match \n
    header = Regexp.last_match[1].strip
    header
  end

  # A synonym for version_name.
  def name
    self.version_name rescue "Tool version ##{self.id}"
  end

  # Sets in the current Ruby process all the environment variables
  # defined in the object. If +use_extended+ is true, the
  # set of variables provided by +extended_environement+ will be
  # applied instead.
  def apply_environment(use_extended = false)
    env   = (use_extended ? self.extended_environment : self.env_array) || []
    saved = ENV.to_hash
    env.each do |name,val|
      if val =~ /\$/
#puts_green "THROUGH BASH: #{name} => #{val}" # debug
        newval = `bash -c 'echo \"#{val.strip}\"'`.strip  # this is quite inefficient, but how else to do it?
#puts_green "RESULT:     : #{name} => #{newval}" # debug
      else
#puts_green "DIRECT      : #{name} => #{val}" # debug
        newval = val
      end
      ENV[name.to_s]=newval.to_s
    end
    return yield
  ensure
#(ENV.keys - saved.keys).each { |spurious| ENV.delete(spurious.to_s); puts_red "SPURIOUS: #{spurious}" } # debug
#saved.each { |k,v| puts_cyan "RESTORED: #{ENV[k]=v.to_s}" unless ENV[k] == v } # debug
    (ENV.keys - saved.keys).each { |spurious| ENV.delete(spurious.to_s) }
    saved.each { |k,v| ENV[k]=v.to_s unless ENV[k] == v }
  end

  # Returns the set of environment variables as stored in
  # the object, plus a few artificial ones for CBRAIN usage.
  #
  #  CBRAIN_GLOBAL_TOOL_CONFIG_ID     : set to self.id if self represents a TOOL's global config
  #  CBRAIN_GLOBAL_BOURREAU_CONFIG_ID : set to self.id if self represents a BOURREAU's global config
  #  CBRAIN_TOOL_CONFIG_ID            : set to self.id
  #  CBRAIN_TC_VERSION_NAME           : set to self.version_name
  def extended_environment
    env = (self.env_array || []).dup
    if self.id.present?
      env << [ "CBRAIN_GLOBAL_TOOL_CONFIG_ID",     self.id.to_s ] if self.bourreau_id.blank?
      env << [ "CBRAIN_GLOBAL_BOURREAU_CONFIG_ID", self.id.to_s ] if self.tool_id.blank?
      env << [ "CBRAIN_TOOL_CONFIG_ID",            self.id.to_s ] if ! self.tool_id.blank? && ! self.bourreau_id.blank?
    end
    env   << [ "CBRAIN_TC_VERSION_NAME",       self.version_name] if self.version_name.present?
    env
  end

  # Generates a partial BASH script that initializes environment
  # variables and is followed a the script prologue stored in the
  # object.
  def to_bash_prologue
    tool     = self.tool
    bourreau = self.bourreau
    group    = self.group

    script = <<-HEADER

#===================================================
# Configuration: # #{self.id} #{self.version_name}
# Tool:          #{tool     ? tool.name     : "ALL"}
# Bourreau:      #{bourreau ? bourreau.name : "ALL"}
# Group:         #{group    ? group.name    : "everyone"}
#===================================================

    HEADER

    if self.tool_id && self.bourreau_id
      desc = self.description || ""
      script += <<-DESC_HEADER
#---------------------------------------------------
# Description:#{desc.blank? ? " (NONE SUPPLIED)" : ""}
#---------------------------------------------------

      DESC_HEADER
      if ! desc.blank?
        desc.gsub!(/\r\n/,"\n")
        desc.gsub!(/\r/,"\n")
        desc_array = desc.split(/\n/).collect { |line| "# #{line}" }
        script += desc_array.join("\n") + "\n\n"
      end
    end

    env = self.env_array || []
    script += <<-ENV_HEADER
#---------------------------------------------------
# Environment variables:#{env.size == 0 ? " (NONE DEFINED)" : ""}
#---------------------------------------------------

    ENV_HEADER
    env.each do |name_val|
      name = name_val[0]
      val  = name_val[1]
      name.strip!
      #val.gsub!(/'/,"'\''")
      script += "export #{name}=\"#{val}\"\n"
    end
    script += "\n" if env.size > 0

    prologue = self.script_prologue || ""
    script += <<-SCRIPT_HEADER
#---------------------------------------------------
# Script Prologue:#{prologue.blank? ? " (NONE SUPPLIED)" : ""}
#---------------------------------------------------

    SCRIPT_HEADER
    prologue.gsub!(/\r\n/,"\n")
    prologue.gsub!(/\r/,"\n")
    prologue += "\n" unless prologue =~ /\n\z/

    script += prologue

    script
  end

  # Generates a partial BASH script that unitializes
  # what the script_prologue did. Unlike for to_bash_prologue,
  # it doesn't undo the settings of the environment variables.
  def to_bash_epilogue
    epilogue = self.script_epilogue || ""
    script = <<-SCRIPT_HEADER
#---------------------------------------------------
# Configuration: # #{self.id} #{self.version_name}
# Script Epilogue:#{epilogue.blank? ? " (NONE SUPPLIED)" : ""}
#---------------------------------------------------

    SCRIPT_HEADER
    epilogue.gsub!(/\r\n/,"\n")
    epilogue.gsub!(/\r/,"\n")
    epilogue += "\n" unless epilogue =~ /\n\z/

    script += epilogue

    script
  end

  # Returns true if the object has no environment variables
  # and its script is blank or only contains blank lines or
  # comments.
  def is_trivial?
    return false if self.extra_qsub_args.present?
    return false if self.containerhub_image_name.present?
    return false if self.container_image_userfile_id.present?
    return false if self.container_engine.present?
    return false if self.cloud_disk_image.present?
    return false if self.cloud_vm_user.present?
    return false if self.cloud_ssh_key_pair.present?
    return false if self.cloud_instance_type.present?
    return false if self.cloud_job_slots.present?
    return false if self.cloud_vm_boot_timeout.present?
    return false if self.cloud_vm_ssh_tunnel_port.present?
    return false if (self.env_array || []).any?(&:present?)
    text = self.script_prologue.to_s + "\n" + self.script_epilogue.to_s
    return true if text.blank?
    text_array = text.split(/\n/).reject { |line| line =~ /\A\s*#|\A\s*\z/ }
    return true if text_array.size == 0
    false
  end

  # Returns true if it's a tool config for bourreau only
  def applies_to_bourreau_only?
    self.bourreau_id.present? && !self.tool_id.present?
  end

  # Returns true if it's a tool config for tool only
  def applies_to_tool_only?
    !self.bourreau_id.present? && self.tool_id.present?
  end

  # Returns true if it's a tool config for bourreau and tool
  def applies_to_bourreau_and_tool?
    self.bourreau_id.present? && self.tool_id.present?
  end

  # These methods call compare_versions defined
  # in cbrain_task, defaulting to this class' compare_versions
  # if cbrain_task doesn't have one.
  # Return true if version_name of the current tool_config
  # is greater than version or false in other case
  def is_at_least_version(version)
     if self.cbrain_task_class.respond_to? :compare_tool_config_versions
       self.cbrain_task_class.compare_tool_config_versions(self.version_name,version) >= 0
     else
       self.class.compare_versions(self.version_name,version) >= 0
     end
  end

  # This method calls any custom compare_versions() method defined
  # in the CbrainTask subclass for the tool of the current tool_config.
  # Returns true if the version_name of the current tool_config
  # is 'the same as' +version+ (as far as compare_versions() thinks).
  def is_version(version)
     if self.cbrain_task_class.respond_to? :compare_tool_config_versions
       self.cbrain_task_class.compare_tool_config_versions(self.version_name,version) == 0
     else
       self.class.compare_versions(self.version_name,version) == 0
     end
  end

  # Compare two tool versions in X.X.X.X format
  # Return -1 if v1 <  v2, for example if v1 = "1.0.2" and v2 = "1.1"
  # Return  0 if v1 == v2, for example if v1 = "2.0.4" and v2 = "2.0.4.0"
  # Return  1 if v1 >  v2, for example if v1 = "0.3"   and v2 = "0.2.4"
  def self.compare_versions(v1, v2)
     v1 = /\d+(\.\d+)*/.match(v1).to_s.split('.').map(&:to_i)
     v2 = /\d+(\.\d+)*/.match(v2).to_s.split('.').map(&:to_i)
     raise ArgumentError, "Could not extract version" if v1.blank? || v2.blank?

     while (v1.size < v2.size) do v1.push(0) end
     while (v2.size < v1.size) do v2.push(0) end

     0.upto(v1.size - 1) { |i| return v1[i] <=> v2[i] unless v1[i] == v2[i] }
     return 0
  end

  # Return the Ruby class associated with the tool associated with this tool_config.
  def cbrain_task_class
    self.tool.cbrain_task_class
  end



  #################################################################
  # Validation methods
  #################################################################

  # Validate some rules for container_engine, container_image_userfile_id, containerhub_image_name
  def container_rules #:nodoc:
    # Should only have one container_engine of particular type
    available_engine = ["Singularity","Docker"]
    if self.container_engine.present? && available_engine.exclude?(self.container_engine)
      errors[:container_engine] = "is not valid"
    end
    # Should only have a containerhub_image_name or a container_image_userfile_id
    if self.containerhub_image_name.present? && self.container_image_userfile_id.present?
      errors[:containerhub_image_name]     = "cannot be set when a container image Userfile ID is set"
      errors[:container_image_userfile_id] = "cannot be set when a container hub name is set"
    end
    # A tool_config with a containerhub_image_name or a container_image_userfile_id should have a container_engine
    if (self.containerhub_image_name.present? || self.container_image_userfile_id.present?) && self.container_engine.blank?
      errors[:container_engine] = "should be set when a container image name or a container userfile ID is set"
    end
    # A tool_config with a container_engine should have a containerhub_image_name or a container_image_userfile_id
    if self.container_engine.present? && ( self.containerhub_image_name.blank? && self.container_image_userfile_id.blank? )
      errors[:container_engine] = "a container hub image name or a container image userfile ID should be set when the container engine is set"
    end

    if self.container_engine.present? && self.container_engine == "Singularity" 
      if self.container_index_location.present? && self.container_index_location !~ /\A[a-z0-9]+\:\/\/\z/i
        errors[:container_index_location] = "is invalid for container engine Singularity. Should end in '://'."
      end
    elsif self.container_engine.present? && self.container_engine == "Docker"
      if self.container_index_location.present? && self.container_index_location !~ /\A[a-z0-9]+([\-\.]{1}[a-z0-9]+)*\.[a-z]{2,6}\z/i
        errors[:container_index_location] = "is invalid for container engine Docker. Should be a valid hostname."
      end
    end
    return errors.empty?
  end

  ##################################################################
  # CARMIN converters
  ##################################################################

  public

  # Returns a CARMIN-compliant structure for their 'Piepline' model.
  # We combine the information of the ToolConfig, and its associated
  # Bourreau and Tool.
  def to_carmin #:nodoc:
    bourreau = self.bourreau
    tool     = self.tool
    {
      :identifier         => self.id,
      :name               => "#{tool.name}@#{bourreau.name}",
      :version            => self.version_name,
      :description        => "#{tool.description}\n#{self.description}".strip,
      :canExecute         => true,
      :parameters         => [ { } ], # PipelineParameter ... TODO
      :properties         => {
        :tool_name    => tool.name,
        :exec_name    => bourreau.name,
        :version_name => self.version_name,
      },
      :errorCodesAndMessages => [], # TODO
    }
  end

end
