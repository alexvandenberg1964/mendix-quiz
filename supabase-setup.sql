-- ============================================================
-- PostNL Mendix Quiz — Supabase Database Setup
-- Run this entire script in the Supabase SQL Editor
-- ============================================================

-- 1. QUESTIONS TABLE
--    correct_index and explanation are hidden from participants via RLS
create table if not exists quiz_questions (
  id          serial primary key,
  week        integer not null,
  category    text not null,
  question    text not null,
  option_a    text not null,
  option_b    text not null,
  option_c    text not null,
  option_d    text not null,
  option_e    text not null,
  correct_index integer not null check (correct_index between 0 and 4),
  explanation text not null,
  created_at  timestamptz default now()
);

-- 2. SUBMISSIONS TABLE
create table if not exists quiz_submissions (
  id           uuid default gen_random_uuid() primary key,
  email        text not null,
  week         integer not null,
  answers      jsonb not null,
  score        integer,
  submitted_at timestamptz default now(),
  unique(email, week)
);

-- ============================================================
-- 3. ROW LEVEL SECURITY
-- ============================================================

alter table quiz_questions enable row level security;
alter table quiz_submissions enable row level security;

-- Participants can only read safe columns (no correct_index, no explanation)
-- This is enforced by only exposing a view — see step 4 below.
-- Block direct table access entirely:
create policy "no direct table read" on quiz_questions
  for select using (false);

-- Submissions: anyone can insert/update their own, read all for leaderboard
create policy "allow insert submissions" on quiz_submissions
  for insert with check (true);

create policy "allow update submissions" on quiz_submissions
  for update using (true);

create policy "allow read submissions" on quiz_submissions
  for select using (true);

-- ============================================================
-- 4. PARTICIPANT-SAFE VIEW (no correct_index, no explanation)
-- ============================================================
create or replace view quiz_questions_public as
  select
    id,
    week,
    category,
    question,
    option_a,
    option_b,
    option_c,
    option_d,
    option_e
  from quiz_questions;

-- Grant anon access to the safe view only
grant select on quiz_questions_public to anon;

-- ============================================================
-- 5. SERVER-SIDE SCORING FUNCTION
--    Called by the app when submitting — correct answers never
--    leave the database. Returns the score to the client.
-- ============================================================
create or replace function submit_quiz_answers(
  p_email  text,
  p_week   integer,
  p_answers jsonb   -- array of 5 integers, e.g. [2, 1, 0, 3, 4]
)
returns integer
language plpgsql
security definer  -- runs as the database owner, bypassing RLS
as $$
declare
  v_score   integer := 0;
  v_q       record;
  v_given   integer;
  v_idx     integer := 0;
begin
  -- Calculate score by comparing answers against correct_index
  for v_q in
    select correct_index
    from quiz_questions
    where week = p_week
    order by id
  loop
    v_given := (p_answers->>v_idx)::integer;
    if v_given = v_q.correct_index then
      v_score := v_score + 1;
    end if;
    v_idx := v_idx + 1;
  end loop;

  -- Upsert the submission with the calculated score
  insert into quiz_submissions (email, week, answers, score, submitted_at)
  values (p_email, p_week, p_answers, v_score, now())
  on conflict (email, week)
  do update set
    answers      = excluded.answers,
    score        = excluded.score,
    submitted_at = excluded.submitted_at;

  return v_score;
end;
$$;

-- Allow anon to call the scoring function
grant execute on function submit_quiz_answers to anon;

-- ============================================================
-- 6. RESULTS FUNCTION
--    Returns a participant's past results WITH correct answers
--    and explanations — but only for weeks already closed
--    (week < current_week). Current week answers stay hidden.
-- ============================================================
create or replace function get_my_results(
  p_email       text,
  p_current_week integer
)
returns table (
  week          integer,
  category      text,
  question      text,
  option_a      text,
  option_b      text,
  option_c      text,
  option_d      text,
  option_e      text,
  correct_index integer,
  explanation   text,
  given_answer  integer,
  is_correct    boolean
)
language plpgsql
security definer
as $$
begin
  return query
    select
      q.week,
      q.category,
      q.question,
      q.option_a,
      q.option_b,
      q.option_c,
      q.option_d,
      q.option_e,
      q.correct_index,
      q.explanation,
      (s.answers->>(row_number() over (partition by q.week order by q.id) - 1)::text)::integer as given_answer,
      ((s.answers->>(row_number() over (partition by q.week order by q.id) - 1)::text)::integer = q.correct_index) as is_correct
    from quiz_questions q
    join quiz_submissions s on s.week = q.week and s.email = p_email
    where q.week < p_current_week
    order by q.week, q.id;
end;
$$;

grant execute on function get_my_results to anon;

-- ============================================================
-- 7. ADMIN FUNCTION — full data including answers
--    Only call this from the admin view
-- ============================================================
create or replace function get_all_questions_admin()
returns table (
  id            integer,
  week          integer,
  category      text,
  question      text,
  option_a      text,
  option_b      text,
  option_c      text,
  option_d      text,
  option_e      text,
  correct_index integer,
  explanation   text
)
language plpgsql
security definer
as $$
begin
  return query
    select q.id, q.week, q.category, q.question,
           q.option_a, q.option_b, q.option_c, q.option_d, q.option_e,
           q.correct_index, q.explanation
    from quiz_questions q
    order by q.week, q.id;
end;
$$;

grant execute on function get_all_questions_admin to anon;

-- ============================================================
-- 8. INSERT ALL 80 QUESTIONS
-- ============================================================

insert into quiz_questions (week, category, question, option_a, option_b, option_c, option_d, option_e, correct_index, explanation) values

-- WEEK 1: Mendix Basics
(1,'Mendix Basics','What is the primary development environment used in Mendix Studio Pro?','Eclipse IDE','A browser-based visual modeler','A desktop application with drag-and-drop modeling','Visual Studio Code with a Mendix plugin','A command-line scaffolding tool',2,'Mendix Studio Pro is a Windows desktop application that provides a visual, model-driven development environment with drag-and-drop capabilities. It is the main tool for professional Mendix developers building full-featured applications.'),
(1,'Mendix Basics','Which of the following best describes the Mendix Runtime?','A cloud-based database engine','The engine that interprets and executes Mendix models at runtime','A CI/CD pipeline tool','A front-end rendering library','A static code compiler that produces Java bytecode',1,'The Mendix Runtime interprets and executes the model-driven application definitions at runtime, handling business logic, page rendering, and data operations. It is not a traditional compiler — it reads and runs the model directly.'),
(1,'Mendix Basics','What is a "module" in Mendix?','A single page in the application','A deployable microservice unit','A self-contained package of domain model, pages, microflows, and other app resources','A third-party npm package','A scheduled background job',2,'A Mendix module is a logical grouping of related application resources such as entities, microflows, pages, and security settings. Modules enable reusability and separation of concerns within one Mendix application.'),
(1,'Mendix Basics','Which Mendix tool is used for collaborative, browser-based low-code development without installing anything?','Mendix Studio Pro','Mendix Studio','Mendix Platform SDK','Mendix Marketplace','Mendix Operations Portal',1,'Mendix Studio is the browser-based, collaborative low-code development environment targeted at business developers. It requires no local installation, unlike Studio Pro which is a Windows desktop application.'),
(1,'Mendix Basics','What does "DTAP" stand for in the context of Mendix deployment environments?','Deploy, Test, Automate, Publish','Development, Test, Acceptance, Production','Design, Transfer, Acceptance, Production','Development, Transfer, Automation, Production','Develop, Track, Approve, Publish',1,'DTAP stands for Development, Test, Acceptance, and Production — the standard four-environment deployment pipeline. Each environment serves a distinct quality-assurance purpose before code reaches end users in Production.'),

-- WEEK 2: Domain Model & Data
(2,'Domain Model & Data','In the Mendix domain model, what is a "generalization"?','A way to filter data in a data grid','An inheritance relationship where one entity inherits attributes from another','A type of database index','A method to export entity data to CSV','A constraint that limits allowed attribute values',1,'Generalization in Mendix implements inheritance. A specialization entity inherits all attributes, associations, and access rules from its generalization (parent) entity, similar to class inheritance in OOP.'),
(2,'Domain Model & Data','Which association type in Mendix allows one entity instance to be linked to multiple instances of another entity, and vice versa?','One-to-one','One-to-many','Many-to-many','Zero-to-one','Unidirectional',2,'A many-to-many association (reference set in Mendix) allows multiple instances of one entity to be associated with multiple instances of another. Mendix creates an intermediary join table in the database for this relationship.'),
(2,'Domain Model & Data','What is the purpose of the "owner" setting on a Mendix association?','Determines who created the entity','Defines which entity side stores the foreign key and therefore "owns" the association','Controls which user can delete the record','Sets the default sort order for the associated objects','Specifies which entity is shown first in the domain model diagram',1,'The owner of an association in Mendix determines which entity holds the foreign key reference in the database. The owning entity side is responsible for maintaining the relationship.'),
(2,'Domain Model & Data','Which attribute type should you use in Mendix to store a precise monetary value without floating-point rounding errors?','Float','Decimal','Integer','Long','Currency (legacy)',1,'The Decimal attribute type uses arbitrary-precision decimal arithmetic, making it suitable for monetary values. Float uses binary floating-point, which introduces rounding errors unacceptable in financial calculations.'),
(2,'Domain Model & Data','What is an "index" in the Mendix domain model used for?','Defining unique constraints on pages','Improving database query performance on frequently searched attributes','Controlling the display order of list views','Encrypting sensitive attribute values','Generating auto-increment primary keys',1,'Database indexes in Mendix are defined on entity attributes to speed up query performance. Adding an index on frequently filtered or sorted attributes can dramatically reduce query time on large datasets.'),

-- WEEK 3: Microflows & Logic
(3,'Microflows & Logic','What is the difference between a microflow and a nanoflow in Mendix?','Microflows run on the server; nanoflows run on the client device','Nanoflows are deprecated in Mendix 9+','Microflows are only for database operations; nanoflows are for UI logic','There is no functional difference; naming is just convention','Nanoflows can only be triggered by scheduled events',0,'Microflows execute server-side on the Mendix Runtime, while nanoflows execute client-side (browser or mobile device). Nanoflows are useful for offline-capable apps and reducing server round-trips for simple logic.'),
(3,'Microflows & Logic','Which activity in a microflow is used to retrieve objects from the database based on an XPath expression?','Create object','Change object','Retrieve','Commit object','Aggregate list',2,'The "Retrieve" activity in a microflow fetches objects from the database. You can retrieve by association or from the database using an XPath constraint to filter results.'),
(3,'Microflows & Logic','What does the "Commit" activity do in a Mendix microflow?','Saves changes to objects in the database permanently','Sends an email notification','Publishes the application to production','Submits a form on the page','Closes the current user session',0,'The Commit activity persists object changes to the database. Without committing, newly created or modified objects exist only in memory and are lost when the session ends or the microflow finishes.'),
(3,'Microflows & Logic','In Mendix, what is an "error handler" on a microflow activity?','A popup shown to the end user when an error occurs','A separate flow path that executes when the activity throws an exception','A log message written to the console','A retry mechanism that re-executes the activity up to 3 times','A rollback that automatically reverts the database on any error',1,'An error handler in Mendix is an alternative path connected to a microflow activity. When the activity raises an exception, execution follows the error handler path instead of terminating the microflow with an unhandled error.'),
(3,'Microflows & Logic','Which expression function in Mendix would you use to get the current date and time on the server?','now()','currentDateTime()','getServerTime()','System.currentTimeMillis()','dateTime()',0,'The now() function in Mendix expressions returns the current server date and time. It is commonly used for setting creation timestamps, calculating deadlines, and comparing dates in microflow conditions.'),

-- WEEK 4: Pages & UI
(4,'Pages & UI','What is the purpose of a "snippet" in Mendix pages?','A reusable UI component that can be placed on multiple pages','A database query shortcut','A type of microflow for UI events','A CSS class definition','A pre-built theme for the entire application',0,'Snippets in Mendix are reusable page fragments embedded in multiple pages. Changes to a snippet are automatically reflected everywhere it is used, reducing duplication and making UI maintenance much easier.'),
(4,'Pages & UI','Which Mendix widget type automatically creates, retrieves, updates, and deletes objects through a form interface?','Data view','List view','Data grid','Template grid','Reference selector',0,'The Data view widget binds to a single object context and provides a form-based interface for viewing and editing its attributes. It is the primary widget for CRUD operations on a single object in Mendix.'),
(4,'Pages & UI','What is a "page parameter" in Mendix used for?','Styling the page with a CSS theme','Passing a context object to a page when it is opened','Defining the page URL route','Setting the page title','Restricting which roles can open the page',1,'A page parameter allows a calling microflow or navigation action to pass an object to the target page. The page can then use this object in its widgets, enabling context-sensitive pages without redundant data retrieval.'),
(4,'Pages & UI','In Mendix, what does the "Conditional visibility" setting on a widget do?','Animates the widget in or out based on user interaction','Shows or hides the widget based on an attribute value or expression at runtime','Locks the widget so it cannot be edited in Studio Pro','Delays widget loading for performance optimization','Collapses the widget to a small icon when not in focus',1,'Conditional visibility in Mendix allows a widget to be shown or hidden at runtime based on an expression or enumeration attribute value. This enables dynamic, context-sensitive UIs without needing separate pages for each state.'),
(4,'Pages & UI','Which page layout in Mendix is best suited for a responsive application that works on both desktop and mobile browsers?','PopupLayout','Responsive','Phone web','Tablet web','NavigationLayout',1,'The Responsive layout in Mendix uses CSS grids and breakpoints to adapt the page layout to different screen sizes, making it suitable for applications accessed on both desktop and mobile browsers.'),

-- WEEK 5: Integration & APIs
(5,'Integration & APIs','What is a Mendix "published REST service"?','A service that consumes external REST APIs','A REST API endpoint exposed by the Mendix application to external consumers','A webhook that triggers microflows','A Mendix Marketplace connector for REST','A scheduled synchronization job for REST data',1,'A published REST service in Mendix allows you to expose microflows as RESTful API endpoints. External systems can then call these endpoints to interact with your Mendix application programmatically.'),
(5,'Integration & APIs','When consuming an external SOAP web service in Mendix, what must you import first?','An OpenAPI (Swagger) specification','A WSDL file that describes the service contract','A Postman collection','A JSON schema definition','An XSD schema file only',1,'SOAP web services are described by WSDL (Web Services Description Language) files. In Mendix, you import the WSDL to automatically generate the necessary request/response entities and the consumed web service configuration.'),
(5,'Integration & APIs','Which Mendix activity is used to call an external REST endpoint from a microflow?','Call web service','Call REST service','HTTP request','Consume REST','Invoke external endpoint',1,'The "Call REST service" activity in a microflow enables calling external REST APIs. You configure the URL, HTTP method, headers, and request/response mapping within this activity.'),
(5,'Integration & APIs','What is the purpose of an "import mapping" in Mendix?','Mapping user roles to module access rules','Converting incoming JSON or XML data into Mendix objects','Translating page labels to multiple languages','Mapping database columns to entity attributes','Defining the schema for a published REST response',1,'Import mappings in Mendix define how incoming JSON or XML structures (from REST or SOAP calls) are converted into Mendix domain model objects. They handle the translation between external data formats and internal entities.'),
(5,'Integration & APIs','What type of authentication does Mendix natively support for published REST services?','Only API key authentication','Username/password, API key, and active session','Only OAuth 2.0','JWT tokens only','No authentication — REST services are always public',1,'Mendix published REST services natively support username/password (HTTP Basic), API keys, and active browser sessions as authentication methods. OAuth can be implemented via custom solutions or Marketplace modules.'),

-- WEEK 6: Security & Access
(6,'Security & Access','In Mendix, what is a "module role"?','A database role that controls SQL permissions','A role defined within a module that groups access rules for its resources','A user group in the Mendix Portal','An API access token scope','A system administrator account',1,'Module roles are defined within a Mendix module and control access to that module''s resources (entities, pages, microflows). They are mapped to application-level user roles to create a complete access control system.'),
(6,'Security & Access','What is XPath-based security in Mendix entity access rules used for?','Encrypting entity data at rest','Restricting which records a user can read, create, update, or delete based on data conditions','Validating input data formats','Auditing changes to entity attributes','Defining the sort order of query results',1,'XPath constraints in entity access rules enable row-level security in Mendix. By adding an XPath expression to an access rule, you restrict which object instances a particular role can access based on attribute values or associations.'),
(6,'Security & Access','Which security level setting in Mendix Studio Pro allows you to test an app without any security checks?','Production','Prototype / demo','Off','Strict','Development only',2,'Setting security level to "Off" in Mendix Studio Pro disables all security checks, allowing developers to run and test the application without configuring access rules. This setting must never be used in production deployments.'),
(6,'Security & Access','What is the purpose of "Demo users" in Mendix security configuration?','Users that can access the admin panel only','Pre-configured test users with specific roles for demonstration purposes','Anonymous users that bypass authentication','External API service accounts','Automated test accounts for unit testing',1,'Demo users in Mendix are predefined test accounts with specific roles that can be used during development and demonstration to quickly test different role-based views without manually creating accounts.'),
(6,'Security & Access','In Mendix, how do you prevent a microflow from being callable by unauthorized users via the API?','Prefix the microflow name with "Private_"','Set the microflow''s "Allowed roles" to specific roles and ensure unauthorized users do not have those roles','Delete the microflow from the published REST service','Add an annotation to the microflow','Set the microflow return type to Void',1,'In Mendix, you control microflow access through the "Allowed roles" setting in the microflow properties. Restricting allowed roles ensures only authenticated users with the appropriate role can invoke the microflow, including via REST APIs.'),

-- WEEK 7: Performance & Deployment
(7,'Performance & Deployment','What is the Mendix "constant" and when would you use it?','A hardcoded value in a microflow expression','A configurable value set per environment used for environment-specific settings like API URLs','A global variable that can be changed at runtime by users','A fixed CSS style value','A database sequence for auto-increment keys',1,'Constants in Mendix are named values configured differently for each deployment environment (DTAP). They are ideal for environment-specific settings such as external service URLs, timeouts, and feature flags.'),
(7,'Performance & Deployment','Which Mendix feature allows you to run long-running background processes without blocking the user interface?','Scheduled events','Background microflows','Nanoflows','Web workers','Queue activities',0,'Scheduled events in Mendix allow microflows to execute on a configurable schedule as background processes. They run independently of user sessions, making them ideal for batch processing and data synchronization.'),
(7,'Performance & Deployment','What is the primary cause of the "N+1 query problem" in Mendix and how is it typically addressed?','Running a Retrieve inside a loop, causing one query per iteration; addressed by retrieving all needed data before the loop','Using too many modules; addressed by splitting into microservices','Having too many attributes on an entity; addressed by normalizing the domain model','Committing objects inside a loop; addressed by batching commits','Having more than 10 concurrent users; addressed by scaling the node',0,'The N+1 problem occurs when a Retrieve activity inside a loop executes one database query per iteration. The solution is to retrieve all required objects before entering the loop and process them in memory.'),
(7,'Performance & Deployment','In Mendix Cloud, what does "scaling" a node refer to?','Increasing the number of modules in the application','Adjusting the memory, CPU, and number of runtime instances allocated to an environment','Compressing static files for faster download','Adding more entities to the domain model','Increasing the database connection timeout',1,'Scaling in Mendix Cloud refers to adjusting compute resources (RAM, CPU) and the number of horizontal runtime instances for an environment. Horizontal scaling adds more runtime instances behind a load balancer to handle increased concurrent user load.'),
(7,'Performance & Deployment','What is the purpose of the Mendix "after startup" microflow?','A microflow that runs when a user logs in','A microflow that executes once when the application starts, used for initialization tasks','A microflow triggered after a page loads','A microflow that runs after every database commit','A microflow that validates the domain model on startup',1,'The "After startup" microflow executes once during application startup, after the runtime has initialized. It is commonly used to set up initial data, establish connections, or perform application-level initialization tasks.'),

-- WEEK 8: Version Control & Teamwork
(8,'Version Control & Teamwork','What version control system does Mendix Studio Pro 10 use by default?','Subversion (SVN)','Git','Mercurial','A proprietary Mendix VCS only','CVS',1,'Mendix Studio Pro 10 introduced native Git support as the default version control system, replacing the older SVN-based Team Server. This aligns Mendix model versioning with mainstream software development workflows.'),
(8,'Version Control & Teamwork','What is a "merge conflict" in Mendix Team Server and how does it typically occur?','A network error during deployment','When two developers modify the same model element simultaneously and the system cannot automatically merge the changes','When a microflow calls itself recursively','When the domain model exceeds the entity limit','When a module import fails due to version incompatibility',1,'A merge conflict occurs when two team members make changes to the same model element. When one developer commits and the other tries to update, Mendix must reconcile conflicting changes, sometimes requiring manual resolution.'),
(8,'Version Control & Teamwork','What is a Mendix "branch line" used for?','Branching a microflow into parallel execution paths','Creating an isolated copy of the application for parallel development, such as a hotfix or feature branch','Splitting a module into two separate modules','Defining conditional logic in a page','Creating a separate domain model for testing',1,'Branch lines in Mendix Team Server work similarly to branches in traditional VCS. They allow teams to create isolated copies of the main line for developing features or fixes in parallel without disrupting the main development line.'),
(8,'Version Control & Teamwork','Before committing changes in Mendix Studio Pro, what should a developer always do?','Deploy to production first','Run the consistency check (F4) to ensure the model has no errors before committing','Delete the local changes and re-download the latest version','Restart Studio Pro','Notify all teammates via email first',1,'Running the consistency check (F4 in Studio Pro) before committing validates the model for errors and warnings. Committing a model with errors would break the application for other team members who update from the repository.'),
(8,'Version Control & Teamwork','In Mendix, what is the "Marketplace" used for?','Purchasing Mendix licenses','Sharing and downloading reusable modules, connectors, and widgets','Deploying applications to cloud environments','Managing application user accounts','Monitoring application performance metrics',1,'The Mendix Marketplace is a platform for sharing and discovering reusable Mendix components, including modules (LDAP, Email, Excel Import), widgets, and connectors. It accelerates development by providing pre-built, community-tested functionality.'),

-- WEEK 9: Best Practices
(9,'Best Practices','What naming convention is recommended for microflows in Mendix?','Use random identifiers for security','Use camelCase with no prefix','Use an action-verb prefix based on purpose, e.g., ACT_, SUB_, IVK_, GD_','Use only numbers as identifiers','Use the entity name followed by the action, with no further convention',2,'Mendix Best Practices recommend prefixed naming conventions for microflows: ACT_ for action microflows, SUB_ for sub-microflows, IVK_ for invoked microflows, and GD_ for get/data microflows. This makes navigation and maintenance easier in large applications.'),
(9,'Best Practices','Why should you avoid using "Retrieve from database" inside a loop in Mendix?','It causes the loop to execute only once','It generates an N+1 query pattern, making performance degrade with data volume','It is not supported inside loops by the Mendix runtime','It resets the loop counter on each execution','It causes uncommitted data to be lost',1,'Retrieving from the database inside a loop is the classic N+1 anti-pattern: for N loop iterations, N separate database queries are issued. As data volumes grow, this severely degrades performance. Retrieve all required data before the loop.'),
(9,'Best Practices','What is the recommended approach for handling sensitive configuration values (like API keys) in a Mendix application?','Hardcode them as string literals in microflows','Store them in constants configured per-environment through the Mendix Portal, not in the model','Store them in a CSV file uploaded to the app','Commit them to version control in a config file','Store them in a String attribute in the domain model',1,'Sensitive values like API keys and connection strings should be stored in Mendix constants and configured via the Mendix Portal for each environment. This keeps secrets out of the model repository and enables environment-specific configuration.'),
(9,'Best Practices','What is the purpose of using "Commit with events: No" in a Mendix microflow?','Prevents data from being saved to the database','Skips the Before/After commit event microflows associated with the entity, improving performance when they are not needed','Makes the commit asynchronous','Only works in nanoflows, not microflows','Commits only changed attributes, not the full object',1,'Setting "With events: No" on a Commit activity skips execution of Before/After commit event microflows. This is useful for bulk operations or system-level imports where validation events are unnecessary and would add significant overhead.'),
(9,'Best Practices','Which Mendix tool provides automated code quality checks and best practice validations for your Mendix model?','Mendix Studio','MendixBot','Mendix Application Quality Monitor (AQM)','Mendix Deployment Manager','Mendix Audit Trail module',2,'The Mendix Application Quality Monitor (AQM) analyzes your Mendix model against best practices and quality metrics. It helps teams identify technical debt, performance risks, and deviations from Mendix guidelines automatically.'),

-- WEEK 10: PostNL & Logistics Context
(10,'PostNL & Logistics Context','In a PostNL shipment tracking app, which entity relationship best models a parcel passing through multiple distribution centers over time?','A single entity "Parcel" with one attribute per distribution center','A "Parcel" entity with a many-to-many to "DistributionCenter" via a "Transit" junction entity','A "Parcel" entity with a one-to-many to a "ScanEvent" entity recording each scan with timestamp and location','Only one entity "TrackingRecord" with all fields denormalized','A "Route" entity with embedded parcel and center data as JSON attributes',2,'Each parcel scan at a distribution center is a distinct event with its own timestamp, location, and status. A one-to-many relationship between Parcel and ScanEvent correctly captures the time-ordered history of a parcel''s journey.'),
(10,'PostNL & Logistics Context','PostNL uses barcode scanning for parcel identification. What is the most appropriate Mendix attribute type for storing a barcode like "3SPOST1234567890"?','Integer','Long','String','AutoNumber','Binary',2,'Barcodes are alphanumeric identifiers that may contain letters and leading zeros. The String attribute type is appropriate. Using Integer or Long would strip leading zeros and cannot store alphabetic characters.'),
(10,'PostNL & Logistics Context','A Mendix application needs to receive real-time shipment status updates from an external system via HTTP callbacks. Which feature is most appropriate?','Scheduled event that polls every 5 minutes','Published REST service that accepts incoming webhook calls','Nanoflow that runs in the browser','Exported Excel import template','A domain event listener in the Mendix Runtime',1,'Publishing a REST service allows the external system to POST status updates directly to the Mendix application as webhook callbacks. This is more efficient than polling because updates are received in real time as events occur.'),
(10,'PostNL & Logistics Context','In a PostNL last-mile delivery app, a driver''s device must work offline. Which Mendix capability supports this?','Published REST service with retry logic','Mendix offline-first mobile app with nanoflows and local data storage','Scheduled events with retry logic','Server-side microflows with in-memory caching','A progressive web app widget from the Marketplace',1,'Mendix supports offline-first mobile applications using nanoflows (client-side logic) and a local SQLite database on the device. Data synchronizes with the server when connectivity is restored, enabling drivers to operate in areas with poor coverage.'),
(10,'PostNL & Logistics Context','For a PostNL operations dashboard showing live parcel volumes, which Mendix feature automatically refreshes data without the user reloading the page?','Browser F5 key instruction to users','Conditional visibility toggle','A data view or list view configured with a polling interval, or the Push Notifications module','A scheduled event that sends an email summary','A JavaScript widget that replaces the entire page DOM',2,'Mendix data views and list views support a configurable polling interval that automatically re-fetches data from the server. For more sophisticated real-time updates, the Mendix Push Notifications module can push events to connected clients without polling.'),

-- WEEK 11: Domain Model & Data (advanced)
(11,'Domain Model & Data','What is the effect of setting "Delete behavior" to "Delete MX object too" on a Mendix association?','When the parent object is deleted, the associated child objects are also automatically deleted','Prevents deletion of the parent if associated children exist','Replaces the child objects with null references','Sends a delete event to associated objects without removing them','Marks children as "archived" instead of deleting',0,'Setting "Delete behavior: Delete MX object too" configures cascading deletes. When the parent entity instance is deleted, Mendix automatically deletes all associated child instances, maintaining referential integrity without manual cleanup microflows.'),
(11,'Domain Model & Data','In Mendix, what is the difference between "Persistent" and "Non-persistent" entities?','Persistent entities are stored in the database; non-persistent exist only in memory for the current session or microflow','Non-persistent entities are faster to create but cannot have associations','Persistent entities require a paid license; non-persistent are free','Non-persistent entities cannot be used in microflows','Non-persistent entities are automatically archived after 24 hours',0,'Persistent entities are backed by database tables and their data survives session termination. Non-persistent entities exist only in application memory and are useful for temporary data structures like search parameter objects or intermediate calculation holders.'),
(11,'Domain Model & Data','Which Mendix attribute type stores an enumeration value?','String','Boolean','Enumeration','Integer','Decimal',2,'Mendix has a dedicated Enumeration attribute type that constrains the attribute value to a predefined set of named options. This provides type safety and readability for status fields, type indicators, and any attribute with a fixed set of allowed values.'),
(11,'Domain Model & Data','What does the System.User entity in Mendix represent?','The database administrator account','The built-in entity representing application users, with associations to user roles for authentication and access control','A log entry for user actions','An external system integration account','A temporary session object',1,'The System.User entity is Mendix''s built-in user account entity. It stores credentials (username, password hash), account status, and associations to user roles. Application-specific user profiles typically specialize or associate with System.User.'),
(11,'Domain Model & Data','What happens to a Mendix String attribute when you set its length to "unlimited"?','It is limited to 255 characters at runtime','It is stored as a CLOB or TEXT type in the database, allowing very large text values','It causes a validation error when saving more than 4000 characters','It automatically truncates content to 65535 characters','It converts the attribute to Binary storage',1,'When a Mendix String attribute is set to unlimited length, it is stored as a CLOB or TEXT type in the underlying database, allowing theoretically unlimited text. Fixed-length strings are stored as VARCHAR with the defined maximum.'),

-- WEEK 12: Microflows & Logic (advanced)
(12,'Microflows & Logic','What is the purpose of the "Rollback" activity in a Mendix microflow?','Reverses all uncommitted changes made to objects in the current transaction since the last commit','Triggers a browser back-navigation','Resets the loop counter in an iteration','Undoes the last deployment to production','Deletes all objects created in the current session',0,'The Rollback activity reverts uncommitted changes to objects. If an error occurs mid-process, rolling back ensures partial changes do not persist, maintaining data consistency within the current transaction boundary.'),
(12,'Microflows & Logic','In Mendix, what is a "Java action" and when would you use it?','A Mendix-specific scripting language for complex calculations','A custom Java class that extends Mendix functionality for operations not possible with standard microflow activities','An automated test script','A JavaScript function embedded in a page widget','A server-side SQL query executed directly against the database',1,'Java actions allow Mendix developers to write custom Java code callable from microflows. They are used when standard Mendix activities are insufficient — for complex cryptographic operations, custom file handling, or integrating native Java libraries.'),
(12,'Microflows & Logic','Which Mendix expression function checks whether a string contains a substring?','contains(subject, search)','indexOf(subject, search) > -1','substring(subject, start, end)','find(subject, search)','matches(subject, regex)',0,'The contains(subject, search) function returns true if the subject string contains the search string as a substring. It is the most straightforward way to perform substring checks in Mendix microflow expressions.'),
(12,'Microflows & Logic','What is the difference between "exclusive split" and "inheritance split" in a Mendix microflow?','Exclusive split routes based on a boolean only; inheritance split routes based on an enumeration only','Exclusive split evaluates multiple conditions with exactly one path taken; inheritance split routes based on the specialization type of an object','They are identical; the names are interchangeable','Exclusive split is for loops; inheritance split is for error handling','Exclusive split runs in parallel; inheritance split runs sequentially',1,'An Exclusive split routes execution based on conditional expressions (boolean, enumeration, comparisons) with exactly one path taken. An Inheritance split routes based on which specialization entity an object is, enabling polymorphic behavior.'),
(12,'Microflows & Logic','In Mendix, what does "Apply context" mean when calling a sub-microflow?','Passes all in-scope objects and the current user session to the sub-microflow automatically','Only applies to nanoflows, not microflows','Shares the database connection string with the sub-microflow','Copies the page layout to the sub-microflow','Makes the sub-microflow run asynchronously',0,'When "Apply context" is enabled on a sub-microflow call, Mendix passes the calling microflow''s context (including in-scope objects and session information) to the sub-microflow, allowing it to access objects not explicitly passed as parameters.'),

-- WEEK 13: Integration & APIs (advanced)
(13,'Integration & APIs','What is an "OData" service in Mendix and what is it primarily used for?','A Mendix-proprietary binary protocol for inter-app communication','An open standard REST-based protocol for exposing queryable data, used with tools like SAP, Power BI, and Excel','A deprecated integration method replaced by REST services','A real-time streaming API protocol','An internal Mendix message bus for module-to-module communication',1,'OData is an open standard for building queryable RESTful APIs ($filter, $select, $expand). In Mendix, you can publish entities as OData services, enabling direct integration with analytics tools like Power BI and Excel without custom microflow logic.'),
(13,'Integration & APIs','When using the Mendix "Call REST service" activity, what does "Custom request template" allow you to do?','Use a Mendix expression to dynamically generate the full request body','Bypass authentication headers automatically','Only send GET requests regardless of method configuration','Limit the response size to 1MB','Force the response to be parsed as XML',0,'The "Custom request template" option allows you to define the request body using a Mendix expression or template, giving full control over the JSON/XML structure sent to the external service. Useful when standard export mapping cannot produce the required format.'),
(13,'Integration & APIs','What is the purpose of "Message definitions" in Mendix?','Defining user-facing error messages for validation','Describing structured JSON/XML message formats shared between import and export mappings','Documenting microflow logic in a structured format','Defining email templates for system notifications','Generating API documentation automatically',1,'Message definitions in Mendix describe the structure of JSON or XML messages shared across multiple import mappings, export mappings, and REST/OData services. They provide a single source of truth for message schemas, reducing duplication.'),
(13,'Integration & APIs','Which approach is recommended for securely passing credentials when calling an external REST API with HTTP Basic Authentication in Mendix?','Append credentials to the URL query string','Store credentials in Mendix constants and reference them in the "Use basic authentication" setting of the Call REST service activity','Hardcode them in the microflow string expression','Pass them as custom JSON body fields','Store them in a domain entity and retrieve them at runtime',1,'Mendix''s Call REST service activity has built-in support for HTTP Basic Authentication. Storing credentials in per-environment constants keeps secrets out of the model while enabling environment-specific credential management.'),
(13,'Integration & APIs','What is "deep link" functionality in Mendix used for?','Linking to external websites from page buttons','Allowing direct navigation to a specific page or context in the Mendix application via a URL, including passing object parameters','Connecting to a SQL database directly from the front-end','Creating hyperlinks between entities in the domain model','Embedding Mendix pages inside external websites via iframes',1,'Deep linking in Mendix (via the Deep Link module from the Marketplace) enables URLs that navigate directly to a specific page with a specific object context. Used for email links, external system integrations, and bookmarkable pages.'),

-- WEEK 14: Security & Access (advanced)
(14,'Security & Access','What is CSRF protection in Mendix and how does it work?','Mendix does not provide CSRF protection — developers must implement it manually','Mendix automatically includes a CSRF token in session cookies and validates it on state-changing requests to prevent cross-site request forgery','CSRF is handled entirely by the browser with no Mendix involvement','CSRF protection must be enabled per microflow via a security annotation','CSRF tokens are validated only for published REST services, not for page actions',1,'Mendix automatically implements CSRF protection by issuing an anti-forgery token stored in a session cookie. This token is validated server-side on all state-changing (non-GET) requests. Developers do not need to implement this manually for standard Mendix pages.'),
(14,'Security & Access','When implementing row-level security in Mendix using XPath constraints, what is the key performance implication?','XPath constraints have no performance impact regardless of data volume','XPath constraints with complex path traversals generate complex SQL WHERE clauses, which can degrade performance on large datasets if unindexed attributes are traversed','XPath constraints bypass the database and run in application memory only','XPath constraints are evaluated only once at login and cached for the entire session','XPath constraints are only evaluated when the entity has more than 1000 records',1,'XPath constraints in entity access rules are translated into SQL WHERE clauses appended to every database query for that entity and role. Complex XPath traversals spanning multiple associations generate expensive joins. Index frequently constrained attributes to mitigate this.'),
(14,'Security & Access','What does the Mendix "anonymous users" setting enable?','Allows users to access the application without authentication, using a shared anonymous user role','Enables guest checkout in e-commerce applications only','Bypasses all security rules for non-logged-in users','Creates a public API endpoint for all microflows','Allows any user to create their own account without an invitation',0,'When anonymous user access is enabled, users can access the application without logging in. Anonymous users are assigned a specific anonymous role with carefully restricted access rules controlling what unauthenticated users can see and do.'),
(14,'Security & Access','What is the purpose of the Mendix "Encryption" module from the Marketplace?','Encrypting the entire Mendix model for IP protection','Providing AES encryption and decryption functions callable from microflows, used for protecting sensitive data at the attribute level','Encrypting REST service network communications (TLS)','Generating SSL certificates for Mendix Cloud deployments','Obfuscating microflow logic from the Mendix model viewer',1,'The Mendix Encryption module provides microflow-callable AES encryption and decryption activities. It is used to encrypt sensitive data stored in entity attributes, adding application-level encryption on top of database security.'),
(14,'Security & Access','Which security-related HTTP header does Mendix Cloud configure by default to protect against clickjacking?','Content-Security-Policy','X-Frame-Options: DENY or SAMEORIGIN','Strict-Transport-Security','X-XSS-Protection','Referrer-Policy: no-referrer',1,'Mendix Cloud automatically configures the X-Frame-Options: DENY or SAMEORIGIN HTTP response header, preventing the application from being embedded in iframes on other domains. This protects users against clickjacking attacks.'),

-- WEEK 15: Performance & Deployment (advanced)
(15,'Performance & Deployment','What is the Mendix Docker Buildpack used for?','Running Mendix applications inside Docker containers for on-premises or private cloud deployments','Building Docker images for front-end Mendix widgets only','Packaging Mendix Marketplace modules for distribution','A deprecated build tool replaced entirely by Mendix Cloud','Generating Kubernetes YAML manifests from Mendix models',0,'The Mendix Docker Buildpack packages a Mendix application deployment archive (MDA) into a Docker container image. This enables Mendix applications to run on Kubernetes, OpenShift, or any Docker-compatible infrastructure outside of Mendix Cloud.'),
(15,'Performance & Deployment','What does "connection pooling" in the Mendix Runtime mean?','Grouping multiple Mendix apps behind one load balancer','Maintaining a pool of pre-established database connections reused across requests, reducing connection overhead','Caching database query results in application memory','Batching multiple HTTP requests into one persistent TCP connection','Distributing database queries across multiple read replicas',1,'Connection pooling means the runtime maintains a configurable pool of open database connections. Rather than opening and closing a connection for every request, connections are borrowed from the pool and returned after use, significantly reducing latency under concurrent load.'),
(15,'Performance & Deployment','In Mendix Cloud, what does the automated backup service cover?','Only the application model (MDA), not data','Both the database and file store, with a defined retention period and point-in-time restore capability','Only manual backups triggered by the operator','The runtime logs and monitoring data only','Only the most recent 7 daily snapshots',1,'Mendix Cloud automatically performs daily database and file store backups for all environments. Production environments typically retain backups for up to 3 months, while non-production environments have shorter retention. Restores can be initiated via the Mendix Portal.'),
(15,'Performance & Deployment','What are Mendix Custom Runtime Settings used for?','They are a frontend CSS configuration file','Runtime configuration parameters (e.g., connection pool size, log levels, JVM heap) applied to the Mendix Runtime, configurable per environment via the Mendix Portal','They are a deprecated configuration format replaced by YAML','They control only the Studio Pro IDE appearance','They define the domain model schema version for database migrations',1,'Custom Runtime Settings allow operators to tune JVM settings, database connection pool sizes, session timeouts, log levels, and other low-level parameters per deployment environment. Configured in the Mendix Portal under environment settings.'),
(15,'Performance & Deployment','What is a "Mendix Deployment Archive" (MDA) file?','A backup file of the Mendix Cloud database','A compressed package containing the compiled Mendix model, resources, and metadata needed to deploy to any compatible runtime environment','The export format for domain model documentation','A license file for Mendix Studio Pro','An encrypted archive of application user data',1,'An MDA (Mendix Deployment Archive) is the deployment artifact produced when you build a Mendix application. It contains the compiled model, static web resources, custom Java code, and metadata. The MDA is uploaded to Mendix Cloud, private cloud, or on-premises environments for deployment.'),

-- WEEK 16: Mixed advanced
(16,'Mendix Basics','What is the major version control change introduced in Mendix Studio Pro 10?','Dropped support for microflows in favor of Java-only development','Migrated from SVN-based Team Server to native Git-based version control','Replaced the Mendix Runtime with a Node.js engine','Removed support for published REST services','Introduced a proprietary binary model format incompatible with earlier versions',1,'Mendix Studio Pro 10 introduced native Git support as the default version control system, replacing the older SVN-based Team Server. This aligns Mendix model versioning with mainstream software development workflows and enables standard Git tooling.'),
(16,'Microflows & Logic','What is the difference between "synchronous" and "asynchronous" microflow calls from a page button?','There is no difference; all microflow calls are synchronous','Synchronous calls block the UI until the microflow completes; asynchronous calls allow the UI to remain responsive while the microflow runs in the background','Asynchronous microflows are only available in nanoflows','Synchronous calls run on the client; asynchronous calls run on the server','Asynchronous calls can only be used with scheduled events, not page buttons',1,'When a microflow is called synchronously from a page, the UI is blocked until the server responds. Asynchronous calls allow the user to continue interacting with the UI while the microflow runs in the background, improving perceived performance for long operations.'),
(16,'Integration & APIs','What is Mendix Catalog (formerly Data Hub) primarily used for?','A marketplace for purchasing Mendix licenses','A centralized catalog for discovering and registering shared OData data services across multiple Mendix applications within an organization','A data warehouse tool for business intelligence analytics','A backup and restore service for Mendix Cloud database snapshots','A code repository for sharing Java actions between teams',1,'Mendix Catalog (formerly Data Hub) is a governance and discoverability layer for shared data services in a Mendix landscape. It catalogs OData services published by Mendix apps, allowing other apps to discover and consume shared data with full contract management and lineage tracking.'),
(16,'Performance & Deployment','What is the purpose of the "Mx Model Reflection" module in Mendix?','Generates UI screenshots of all pages for documentation','Provides runtime access to the Mendix model metadata (entities, attributes, modules) so applications can dynamically work with domain model information','Automatically generates unit tests for all microflows','Creates a visual diagram export of all microflows','Synchronizes the Mendix domain model with an external database schema',1,'The Mx Model Reflection module exposes Mendix domain model metadata at runtime as queryable Mendix objects. This enables advanced use cases like dynamically generated forms, generic data import/export tools, and runtime inspection of entity structures.'),
(16,'Best Practices','What is Mendix Flex and how does it differ from traditional Mendix Cloud licensing?','Mendix Flex is a front-end CSS styling framework','Mendix Flex is a consumption-based licensing model where you pay for actual runtime usage rather than fixed node sizes, offering more flexibility for variable workloads','Mendix Flex is the product name for offline-first Mendix mobile apps','Mendix Flex is an on-premises deployment model with no cloud dependency','Mendix Flex is a beta program for early access to new Studio Pro features',1,'Mendix Flex (Mendix Cloud Flex) introduced a consumption-based pricing model as an alternative to fixed-node pricing. Organizations pay based on actual compute consumption, which can be more cost-effective for applications with variable or unpredictable load patterns.');
