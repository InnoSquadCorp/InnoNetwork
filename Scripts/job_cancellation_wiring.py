"""Pure reviewed workflow expressions for default-on per-job stale PR cancellation."""
import json

FLAG = "(vars.INNO_JOB_CANCELLATION == '' || vars.INNO_JOB_CANCELLATION == 'enabled') && github.event_name == 'pull_request'"


def lane(label):
    return "contains(github.event.pull_request.labels.*.name, '"+label+"') && '"+label+"' || 'no-"+label+"'"


def outer_group(original, lane_labels):
    # Feature-on PR runs share admission only with the same head, base branch and
    # lanes: a metadata run queues behind that validation without holding a runner.
    lanes = ''.join('-{' + str(i + 2) + '}' for i in range(len(lane_labels)))
    return original + ("${{ (" + FLAG + ") && format('-head-{0}-base-{1}" + lanes + "', github.event.pull_request.head.sha, "
                       "github.event.pull_request.base.ref" + ''.join(', ' + lane(label) for label in lane_labels) + ") || '' }}")


def inner(value):
    if type(value) is bool: return str(value).lower()
    if isinstance(value, str) and value.startswith('${{ ') and value.endswith(' }}'):return value[4:-3]
    raise ValueError('unreviewed original concurrency/timeout expression')


def outer_cancel(original):
    return '${{ !(' + FLAG + ') && (' + inner(original) + ') }}'


def active(metadata, products=(), product_key=None):
    expression = FLAG + ' && !(' + metadata + ')'
    if products:
        scoped = '(' + ' || '.join("(vars." + variable + " == '' || vars." + variable + " == 'true')" for variable in products) + ')'
        expression += ' && (!' + scoped + " || " + (product_key or "''") + " != '')"
    return expression


def job_fields(workflow, job, metadata, axes=(), products=(), product_key=None, lane_labels=('release-validation',)):
    enabled = active(metadata, products, product_key)
    group = ('scoped-job-v1-${{ github.repository }}-${{ github.workflow }}-' + workflow + '-' + job +
             '-pr-${{ github.event.pull_request.number }}-base-${{ github.event.pull_request.base.ref }}')
    for label in lane_labels:
        group += "-${{ " + lane(label) + " }}"
    for axis in axes:
        group += '-${{ ' + axis + ' }}'
    if products:
        scoped = '(' + ' || '.join("(vars." + variable + " == '' || vars." + variable + " == 'true')" for variable in products) + ')'
        group += '-${{ ' + scoped + ' && ' + (product_key or "''") + " || 'full-package' }}"
    group += "-${{ (" + enabled + ") && 'active' || format('off-{0}-{1}', github.run_id, github.run_attempt) }}"
    return {'group': group, 'cancel-in-progress': '${{ ' + enabled + ' }}'}


def workload_key(repository, workflow, job, pr, base, lane, matrix, *, enabled=True, metadata=False, product_mode=False, run=1, attempt=1):
    """Executable key model for collision/default/metadata negative controls."""
    data = [repository, workflow, job, pr, base, lane, matrix]
    if not enabled or metadata or product_mode: data += ['off', run, attempt]
    return json.dumps(data, sort_keys=True, separators=(',', ':'))


def validate_workflow(document, entry, config, filename):
    original = entry['original_concurrency']
    if original is not None:
        expected = {**original, 'group': outer_group(original['group'], config['lane_labels']),
                    'cancel-in-progress': outer_cancel(original['cancel-in-progress'])}
        if document.get('concurrency') != expected:
            raise ValueError('outer default/metadata concurrency contract changed')
    for name, item in entry['jobs'].items():
        expected = job_fields(filename, name, config['metadata'], item['axes'],
                              item['product_flags'], item.get('product_key'), config['lane_labels'])
        job = document['jobs'][name]
        if job.get('concurrency') != expected:
            raise ValueError('job cancellation scope/condition changed: '+name)
        if job.get('strategy', {}).get('matrix', {}) != item['matrix']:
            raise ValueError('matrix workload requires key review: '+name)
    for name, original_concurrency in entry.get('excluded_concurrency', {}).items():
        if document['jobs'][name].get('concurrency') != original_concurrency:
            raise ValueError('excluded stateful/aggregate concurrency changed: '+name)
    # A metadata gate is one bounded verifier call. Its run waits for validation in
    # the shared admission group, never on a runner.
    for name, metadata in entry['metadata_gates'].items():
        job=document['jobs'][name]
        if job['timeout-minutes'] != metadata['timeout']:
            raise ValueError('metadata gate timeout contract changed')
        steps=[s for s in job['steps'] if s.get('name')=='Verify prior validation for metadata']
        if len(steps)!=1 or steps[0]['run']!=metadata['command']:
            raise ValueError('authoritative metadata command changed, wrapped or bypassed')
