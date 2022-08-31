
#
# CBRAIN Project
#
# Copyright (C) 2008-2022
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

module BoutiquesForcedOutputBrowsePath

  # Note: to access the revision info of the module,
  # you need to access the constant directly, the
  # object method revision_info() won't work.
  Revision_info=CbrainFileRevision[__FILE__] #:nodoc:

  ##################################################
  # Cluster side overrides
  ##################################################

  # This method overrides the method in BoutiquesClusterTask.
  # If the name for the file contains a relative path such
  # as "a/b/c/hello.txt", it will extract the "a/b/c" and
  # provide it in the browse_path attribute to the Userfile
  # constructor in super().
  def safe_userfile_find_or_new(klass, attlist)
    name = attlist[:name]
    return super(klass, attlist) if ! (name.include? "/") # if there is no relative path, just do normal stuff

    # Find all the info we need
    attlist = attlist.dup
    dp_id   = attlist[:data_provider_id] || self.results_data_provider_id
    dp      = DataProvider.find(dp_id)
    pn      = Pathname.new(name)  # "a/b/c/hello.txt"

    # Make adjustements to name and browse_path
    attlist[:name] = pn.basename.to_s  # "hello.txt"
    if dp.has_browse_path_capabilities?
      attlist[:browse_path] = pn.dirname.to_s   # "a/b/c"
      self.addlog "BoutiquesForcedOutputBrowsePath: result DataProvider browse_path will be '#{pn.dirname}'"
    else
      attlist[:browse_path] = nil # ignore the browse_path
      self.addlog "BoutiquesForcedOutputBrowsePath: result DataProvider doesn't have multi-level capabilities, ignoring forced browse_path '#{pn.dirname}'."
    end

    # Invoke the standard code
    return super(klass, attlist)
  end

  # This method overrides the method in BoutiquesClusterTask.
  # After running the standard code, it will prepend a
  # browse path to the "name" returned to the caller.
  # Note that this kind of modification should really happen
  # only AFTER any other overrides to this method (e.g. what
  # happens in the other module BoutiquesOutputFilenameRenamer )
  def name_and_type_for_output_file(output, pathname)
    if self.getlog.to_s !~ /BoutiquesForcedOutputBrowsePath rev/
      self.addlog("BoutiquesForcedOutputBrowsePath rev. #{Revision_info.short_commit}") # only log this once
    end
    name, type  = super # the standard names and types; the name will be replaced
    descriptor  = descriptor_for_save_results
    config      = descriptor.custom_module_info('BoutiquesForcedOutputBrowsePath')
    browse_path = config[output.id]  # "a/b/c"
    return [ name, type ] if browse_path.blank? # no configured browse_path for this output
    combined    = (Pathname.new(browse_path) + name).to_s # "a/b/c/name"
    [ combined, type ]
  end

end
