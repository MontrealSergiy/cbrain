
#
# CBRAIN Project
#
# Copyright (C) 2008-2024
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

# Removes the workdir of a CBRAIN task.
#
# Must be run on a Bourreau only (see superclass).
class BackgroundActivity::RemoveTaskWorkdir < BackgroundActivity::TerminateTask

  Revision_info=CbrainFileRevision[__FILE__] #:nodoc:

  def process(item)
    super(item) # invokes the terminate code; will skip tasks that don't need to be terminated
    cbrain_task  = CbrainTask.where(:bourreau_id => CBRAIN::SelfRemoteResourceId).find(item)
    ok           = cbrain_task.send(:remove_cluster_workdir) # it's a protected method
    return [ true,  "Cleaned" ] if   ok
    return [ false, "Skipped" ] if ! ok
  end

  def prepare_dynamic_items
    populate_items_from_task_custom_filter
  end

end

