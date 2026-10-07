"""Pure reviewed workflow expressions for default-on per-job stale PR cancellation."""
import json

FLAG = "(vars.INNO_JOB_CANCELLATION == '' || vars.INNO_JOB_CANCELLATION == 'enabled') && github.event_name == 'pull_request'"


def outer_group(original):
    return original + "${{ (" + FLAG + ") && format('-jobs-{0}-{1}', github.run_id, github.run_attempt) || '' }}"


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
        group += "-${{ contains(github.event.pull_request.labels.*.name, '"+label+"') && '"+label+"' || 'no-"+label+"' }}"
    for axis in axes:
        group += '-${{ ' + axis + ' }}'
    if products:
        scoped = '(' + ' || '.join("(vars." + variable + " == '' || vars." + variable + " == 'true')" for variable in products) + ')'
        group += '-${{ ' + scoped + ' && ' + (product_key or "''") + " || 'full-package' }}"
    group += "-${{ (" + enabled + ") && 'active' || format('off-{0}-{1}', github.run_id, github.run_attempt) }}"
    return {'group': group, 'cancel-in-progress': '${{ ' + enabled + ' }}'}


def metadata_timeout(original, metadata):
    original_expression = str(original) if type(original) is int else inner(original)
    return '${{ (' + FLAG + ') && (' + metadata + ') && 360 || (' + original_expression + ') }}'


def wrapped_command(original, scripts):
    return 'python3 -B ' + scripts + '/metadata_wait.py -- ' + original


def workload_key(repository, workflow, job, pr, base, lane, matrix, *, enabled=True, metadata=False, product_mode=False, run=1, attempt=1):
    """Executable key model for collision/default/metadata negative controls."""
    data = [repository, workflow, job, pr, base, lane, matrix]
    if not enabled or metadata or product_mode: data += ['off', run, attempt]
    return json.dumps(data, sort_keys=True, separators=(',', ':'))


def validate_workflow(document, entry, config, filename):
    original = entry['original_concurrency']
    if original is not None:
        expected = {**original, 'group': outer_group(original['group']),
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
    for name, metadata in entry['metadata_gates'].items():
        job=document['jobs'][name]
        if job['timeout-minutes'] != metadata_timeout(metadata['timeout'], config['metadata']):
            raise ValueError('metadata observer timeout contract changed')
        steps=[s for s in job['steps'] if s.get('name')=='Verify prior validation for metadata']
        if len(steps)!=1 or steps[0]['run']!=wrapped_command(metadata['command'],config['scripts']):
            raise ValueError('authoritative metadata command changed or bypassed')
        if steps[0].get('env',{}).get('INNO_JOB_CANCELLATION')!="${{ (vars.INNO_JOB_CANCELLATION == '' || vars.INNO_JOB_CANCELLATION == 'enabled') && 'enabled' || 'disabled' }}":
            raise ValueError('metadata rollout flag not propagated')
