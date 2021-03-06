require 'puppet/type'

Puppet::Type.type(:package).provide(:docker_el) do
  confine :feature => :docker
  has_features :versionable

  def dockerfile_line(context)
    version = @resource[:ensure]
    script = "RUN yum install #{@resource[:name]}"

    case version
    when :latest
    when :present
    when :absent
    when :installed
    else
      script += "-#{version}"
    end

    # TODO: Honor other attributes. Source, install_options, etc.

    script += " -y"
    script
  end
end
