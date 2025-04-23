<img align="left" height="84" src="https://us.v-cdn.net/6031871/uploads/6FEZSWRBOGEG/01-servicenow-logo-standard-rgb-tm-600dpi-gg-2ba-050418.png">
<img align="left" height="60" src="https://pendo-static-5165737070428160.storage.googleapis.com/-_OOs10RV-vf5M7IDJK72MHJ1hg/guide-media-7ee1a933-a48c-435b-821e-6579d1f3cab9">
<h1>servicenow-tlm</h1>

<br/>

## Overview

### General

The `servicenow-tlm` repository stores the application files that have been committed for an application. \
The application is DigiCert® Trust Lifecycle Manager integration into ServiceNow.

<br/>
<br/>

---

<br/>

## Local Development

### Prerequisites

1. [ServiceNow personal development][5] instance or DigiCert ServiceNow instance (https://ven05840.service-now.com/) up and running.

### Development

1. Use Studio to [load application][6] to a development instance for further development or testing.
2. [Commit changes][7] to this repository via Studio.

**Notes:** All updates related to application UI are done in the scope of [`servicenow-tlm-react-app`][8] application. \
The deployment process of [`servicenow-tlm-react-app`][8] application's build is described in [Deployment](https://github.com/digicert/servicenow-tlm-react-app/tree/master#deployment) section.

<br/>

---

<br/>

## Versioning

As usual, the new minor version tag is added to the latest commit in the `main` branch at the end of each sprint. \
Be sure that the version tag of the application coincides with the version of the [`servicenow-tlm-react-app`][8] application.

e.g.,

```bash
git tag -a v1.3.0 -m "STI-2023-9" -m "
- STI-92: Enable Profiles for SNOW User Roles
- STI-150: TLS CertCentral Certificate (CSR) driven - Revoke
- STI-177: Sync deleted/suspended profiles from DC1 TLM on \"Sync profiles\" action

git push origin v1.3.0
```

<br/>

---

<br/>

## Releasing 🚀

The first version of the application has been released to [ServiceNow Store][9].

To release the new version do the following from Studio:

- Create a `release` branch as follows: `release/x.x.0`
- Add changes needed only for this release (if such are needed) to this `release` branch
- Add version tag to the latest commit in this `release` branch
- Push the `release` branch and version tag to `origin`

For the hotfixes:

- Switch to the needed `release` branch, where the functionality should be fixed
- Add fix
- Commit and add a version tag with incremented hotfix version to this commit, e.g., `v1.2.1`

<br/>

---



### Learn More 📖

**ServiceNow DigiCert TLM integration**

- [Confluence pages][10]

**ServiceNow Documentation**

- [ServiceNow Docs][1]
- [ServiceNow for Developers][3]
- [ServiceNow Community][3]
- [Linking an Application to Source Control][4]


[1]: https://docs.servicenow.com/
[2]: https://docs.servicenow.com/bundle/utah-api-reference/page/script/server-scripting/reference/r_UIPages.html
[3]: https://www.servicenow.com/community/
[4]: https://developer.servicenow.com/dev.do#!/learn/courses/utah/app_store_learnv2_devenvironment_utah_managing_the_development_environment/app_store_learnv2_devenvironment_utah_source_control/app_store_learnv2_devenvironment_utah_linking_an_application_to_source_control
[5]: https://developer.servicenow.com/dev.do#!/learn/learning-plans/utah/new_to_servicenow/app_store_learnv2_buildmyfirstapp_utah_personal_developer_instances
[6]: https://developer.servicenow.com/dev.do#!/learn/courses/utah/app_store_learnv2_devenvironment_utah_managing_the_development_environment/app_store_learnv2_devenvironment_utah_source_control/app_store_learnv2_devenvironment_utah_importing_an_application_from_source_control
[7]: https://developer.servicenow.com/dev.do#!/learn/courses/utah/app_store_learnv2_devenvironment_utah_managing_the_development_environment/app_store_learnv2_devenvironment_utah_source_control/app_store_learnv2_devenvironment_utah_committing_changes
[8]: https://github.com/digicert/servicenow-tlm-react-app
[9]: https://store.servicenow.com/sn_appstore_store.do#!/store/application/775fcb0f87bda510939bfc07cebb35a3
[10]: https://digicertinc.atlassian.net/wiki/spaces/S/overview?homepageId=5824185764

