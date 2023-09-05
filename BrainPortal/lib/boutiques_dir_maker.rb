
#
# CBRAIN Project
#
# Copyright (C) 2008-2023
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

# Some tools expect that a directory e.g. results, etc exists in the working directory
#
# While traditionally we add to the boutiques command line prefix akin to 'mkdir -p [OUTPUT];'
# external collabortors might deslike poluting the command line with technical staff
# or need a clean boutiques descriptro which does not create any new folders
# For example :
#
#
# and in the `cbrain:integrator_modules` section look like:
#
#     "BoutiquesDirMaker":
#          [ "[OUTDIR]", "[OUTDIR]/[THRESHOLD]_res", "tmp" ]
#
module BoutiquesDirMaker

  # Note: to access the revision info of the module,
  # you need to access the constant directly, the
  # object method revision_info() won't work.
  Revision_info=CbrainFileRevision[__FILE__] #:nodoc:

  ############################################
  # Bourreau (Cluster) Side Modifications
  ############################################

  # Add mkdir to json descriptor
  def cluster_commands
    descriptor = super.dup()
    dir_names  = descriptor.custom_module_info('BoutiquesDirMaker')

    # Log revision information
    basename = Revision_info.basename
    commit   = Revision_info.short_commit
    self.addlog("Creating directories with BoutiquesDirMaker.")
    self.addlog("#{basename} rev. #{commit}")

    dir_names = dir_names.map {|x| "'" + x.gsub(/[^0-9A-Za-z.\/\-_\[\]]|(\.\.+)/, '') + "'"}  # silent sanitizing and quotes

    descriptor.command_line = "mkdir -p '" + dir_names.join(' ') + "; " + descriptor.command_line

    descriptor
  end
end