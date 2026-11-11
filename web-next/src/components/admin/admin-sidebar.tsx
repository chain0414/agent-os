"use client"

import {
  Activity,
  Gauge,
  Info,
  KeyRound,
  Laptop,
  LineChart,
  Mail,
  Megaphone,
  SlidersHorizontal,
  UserCog,
  Users,
} from "lucide-react"
import { useTranslations } from "next-intl"

import { useAuth } from "@/components/auth/auth-context"
import { WorkspaceSectionSidebar } from "@/components/workspace-section-sidebar"
import { useWorkspace } from "@/components/workspace-context"
import {
  adminNavigation,
  isAdminSectionAvailable,
  isAdminServiceSection,
  servicePageKey,
  type AdminSection,
} from "@/features/admin/navigation"

const ICONS = {
  overview: LineChart,
  users: Users,
  usage: Gauge,
  devices: Laptop,
  quality: Activity,
  team: UserCog,
  announcements: Megaphone,
  "service-general": SlidersHorizontal,
  "service-auth": KeyRound,
  "service-email": Mail,
  "service-info": Info,
} satisfies Record<AdminSection, typeof LineChart>

export function AdminSidebar({ contained = false }: { contained?: boolean }) {
  const t = useTranslations("admin")
  const tTabs = useTranslations("pages.opsDashboard.tabs")
  const tTeam = useTranslations("pages.team")
  const tService = useTranslations("pages.service")
  const tAnnouncement = useTranslations("announcement.admin")
  const { adminSection, navigate } = useWorkspace()
  const { devkit } = useAuth()
  const managedOnly = devkit?.managedOnly === true

  const label = (section: AdminSection): string => {
    if (section === "team") return tTeam("title")
    if (section === "announcements") return tAnnouncement("title")
    if (isAdminServiceSection(section)) return tService(`sections.${servicePageKey(section)}.title`)
    return tTabs(section)
  }

  return (
    <WorkspaceSectionSidebar<AdminSection>
      contained={contained}
      title={t("title")}
      activeId={isAdminSectionAvailable(adminSection, managedOnly) ? adminSection : "announcements"}
      onNavigate={(section) => navigate("admin", section)}
      groups={adminNavigation.map(({ group, sections }) => ({
        id: group,
        label: t(`groups.${group}`),
        items: sections
          .filter((section) => isAdminSectionAvailable(section, managedOnly))
          .map((section) => ({ id: section, label: label(section), icon: ICONS[section] })),
      })).filter(({ items }) => items.length > 0)}
    />
  )
}
