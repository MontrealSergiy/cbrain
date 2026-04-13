#
# CBRAIN Project
#
# Copyright (C) 2024
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

# Helper methods for generating and managing fake outputs
# for Boutiques-integrated tasks.
module BoutiquesFakeOutputs

  Revision_info = CbrainFileRevision[__FILE__] #:nodoc:

  # Returns true if the given user (or current user)
  # is allowed to use the fake output mechanism.
  # at the moment check that task user (or specificed user)
  # is admin
  def fake_outputs_available_to_user?(user = nil)
    user ||= self.user
    return false unless user
    return true if user.has_role?(:admin_user)
    # for now admin feature, allow selected users...
  end

  # Returns true if fake outputs are enabled for this task.
  def fake_outputs_enabled?
    return false unless self.params && self.params[:enable_fake_outputs].to_s == "1"
    fake_outputs_available_to_user?     #  disable for non-admin task owner
  end

  # Validate fake output specs (portal side).
  # Allowed values: blank, "fakefile", "fakedir", or a numeric userfile ID.
  def validate_fake_output_specs(descriptor)
    return true unless self.params
    enable = self.params[:enable_fake_outputs].to_s == "1"
    specs = fake_output_specs
    return true if specs.blank? && !enable

    unless fake_outputs_available_to_user?
      params_errors.add(:base, "Fake outputs are only available to admins tasks.") if enable || specs.present?
      return false
    end

    outputs    = descriptor.output_files || []
    output_ids = outputs.map { |o| o.id.to_s }
    ok = true

    unknown = specs.keys - output_ids
    unknown.each do |oid|
      params_errors.add("fake_output_specs[#{oid}]", "is not a valid output ID")
      ok = false
    end

    specs.each do |oid, spec|
      next unless output_ids.include?(oid)
      s = spec.to_s.strip
      next if s.blank?
      if s.casecmp("fakefile").zero? || s.casecmp("fakedir").zero?
        next
      elsif s =~ /\A\d+\z/
        uf = Userfile.find_accessible_by_user(s.to_i, self.user, :access_requested => file_access_symbol()) rescue nil
        if uf.nil?
          params_errors.add("fake_output_specs[#{oid}]", "references a userfile you cannot access (ID #{s})")
          ok = false
        end
      else
        params_errors.add("fake_output_specs[#{oid}]", "must be 'fakefile', 'fakedir', or a numeric userfile ID")
        ok = false
      end
    end
    ok
  end

  # Returns the hash of output ID => fake spec string.
  def fake_output_specs
    return {} unless self.params
    specs = self.params[:fake_output_specs]
    specs = specs.to_unsafe_h if specs.respond_to?(:to_unsafe_h)
    specs = specs.to_h if specs.respond_to?(:to_h)
    specs ||= {}
    return {} unless specs.is_a?(Hash)
    normalized = {}
    specs.each { |k, v| normalized[k.to_s] = v }
    normalized
  end

end
